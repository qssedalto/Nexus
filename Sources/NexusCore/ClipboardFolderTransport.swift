import Foundation

/// A user-selected iCloud Drive directory is the transport. This deliberately
/// requests NO iCloud/CloudKit entitlements and never contacts an Apple API.
/// The system's File Provider handles synchronization outside this process.
///
/// Protocol v1 stores immutable, UUID-named JSON changes. The caller retains
/// its SQLite journal and applies deterministic record merges. Binary payloads
/// are intentionally unsupported until a verified asset protocol exists.
public actor ClipboardFolderTransport: ClipboardCloudTransport, ClipboardCloudPrivateZoneDeletion {
    public enum FolderError: Error, LocalizedError, Sendable {
        case invalidDirectory, notPrepared, unsupportedAsset, invalidDocument
        case oversizedDocument, conflictingMutation, inaccessibleFile

        public var errorDescription: String? {
            switch self {
            case .invalidDirectory: "Choose the NexusClipboardSync folder."
            case .notPrepared: "Prepare the selected NexusClipboardSync folder first."
            case .unsupportedAsset: "Original image and file transfer is not yet supported."
            case .invalidDocument: "A sync document has an invalid format."
            case .oversizedDocument: "A sync document exceeds the allowed size."
            case .conflictingMutation: "The same mutation identifier has different contents."
            case .inaccessibleFile: "The selected folder cannot be accessed."
            }
        }
    }

    public static let folderName = "NexusClipboardSync"
    private static let markerName = ".nexus-folder-sync-v1"
    private static let maxBytes = 256 * 1_024
    private let root: URL

    private struct Envelope: Codable {
        let schemaVersion: Int
        let record: ClipboardCloudRecord
    }

    public init(folderURL: URL) {
        root = folderURL.standardizedFileURL
    }

    /// Explicit initialization only, after the user selects the directory.
    public func prepareFolderIfRequested() throws {
        try withAccess {
            let marker = root.appendingPathComponent(Self.markerName)
            let directory = changesURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("Nexus clipboard folder protocol v1\n".utf8)
                    .write(to: marker, options: .atomic)
            }
        }
    }

    public func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck] {
        var acknowledgements: [ClipboardCloudUploadAck] = []
        for record in records {
            try Task.checkCancellation()
            guard await permissionCheck(record) else { continue }
            _ = try record.validated()
            guard !Self.hasBinaryReference(record) else { throw FolderError.unsupportedAsset }
            let bytes = try JSONEncoder().encode(Envelope(schemaVersion: 1, record: record))
            guard bytes.count <= Self.maxBytes else { throw FolderError.oversizedDocument }
            try withAccess {
                try requirePrepared()
                let target = changesURL().appendingPathComponent(record.mutationID + ".json")
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var failure: Error?
                coordinator.coordinate(writingItemAt: target, options: [], error: &coordinationError) { coordinatedURL in
                    do {
                        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                            let current = try Data(contentsOf: coordinatedURL)
                            guard current == bytes else { throw FolderError.conflictingMutation }
                        } else {
                            try bytes.write(to: coordinatedURL, options: .atomic)
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
                if let coordinationError { throw coordinationError }
            }
            acknowledgements.append(ClipboardCloudUploadAck(
                id: record.id, mutationID: record.mutationID
            ))
        }
        return acknowledgements
    }

    /// A cycling index is intentional: newly-arrived File Provider entries
    /// can appear anywhere in lexical order. When a pass reaches the end,
    /// replay starts from zero; the journal deduplicates known mutations.
    /// This gives eventual replay without an ever-growing token or trusting
    /// unreliable cross-device modification timestamps.
    public func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage {
        try Task.checkCancellation()
        return try withAccess {
            try requirePrepared()
            let files = try FileManager.default.contentsOfDirectory(
                at: changesURL(), includingPropertiesForKeys: nil
            ).filter {
                $0.pathExtension == "json" &&
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let provided = token.flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(Int.init) ?? 0
            let start = (provided >= 0 && provided < files.count) ? provided : 0
            let end = min(files.count, start + 200)
            var records: [ClipboardCloudRecord] = []
            for url in files[start..<end] {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var content: Data?
                var failure: Error?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                    do {
                        let metadata = try FileManager.default.attributesOfItem(atPath: coordinated.path)
                        guard let length = metadata[.size] as? NSNumber,
                              length.intValue > 0, length.intValue <= Self.maxBytes else {
                            throw FolderError.oversizedDocument
                        }
                        content = try Data(contentsOf: coordinated)
                    } catch { failure = error }
                }
                if let failure { throw failure }
                if let coordinationError { throw coordinationError }
                guard let content,
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: content),
                      envelope.schemaVersion == 1,
                      UUID(uuidString: envelope.record.mutationID) ==
                        UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      (try? envelope.record.validated()) != nil,
                      !Self.hasBinaryReference(envelope.record) else {
                    throw FolderError.invalidDocument
                }
                records.append(envelope.record)
            }
            let more = end < files.count
            let next = more ? end : 0
            return ClipboardCloudDownloadPage(
                changes: records,
                token: Data(String(next).utf8),
                moreComing: more
            )
        }
    }

    /// Explicit DELETE-only operation. Never touches other user documents,
    /// the selected root, or data outside Nexus's protocol-owned UUID files.
    public func deletePrivateNexusZone() async throws {
        try withAccess {
            try requirePrepared()
            let files = try FileManager.default.contentsOfDirectory(
                at: changesURL(), includingPropertiesForKeys: nil
            )
            for url in files where url.pathExtension == "json" &&
                UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func changesURL() -> URL {
        root.appendingPathComponent("changes", isDirectory: true)
    }

    private func requirePrepared() throws {
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent(Self.markerName).path
        ) else { throw FolderError.notPrepared }
    }

    private func withAccess<T>(_ operation: () throws -> T) throws -> T {
        guard root.lastPathComponent == Self.folderName,
              (try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))?.isDirectory == true,
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        else { throw FolderError.invalidDirectory }
        let secured = root.startAccessingSecurityScopedResource()
        defer { if secured { root.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private static func hasBinaryReference(_ record: ClipboardCloudRecord) -> Bool {
        guard case .operation(let operation)? = record.payload else { return false }
        return operation.image != nil || operation.file != nil
    }
}
