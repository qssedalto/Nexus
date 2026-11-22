import Foundation

/// An acknowledgement must identify the exact mutation. A matching record ID
/// alone is not enough when a user edits an entry during an in-flight upload.
public struct ClipboardCloudUploadAck: Sendable, Hashable {
    public let id: String
    public let mutationID: String

    public init(id: String, mutationID: String) {
        self.id = id
        self.mutationID = mutationID
    }
}

public struct ClipboardCloudDownloadPage: Sendable {
    public let changes: [ClipboardCloudRecord]
    public let token: Data?
    public let moreComing: Bool
    /// Independently authorized binary image assets keyed by operation ID.
    /// These are saved alongside journal records and cursor atomically.
    public let imageAssets: [String: ClipboardCloudImageAsset]
    public let fileAssets: [String: ClipboardCloudFileAsset]

    public init(changes: [ClipboardCloudRecord], token: Data?,
                moreComing: Bool = false,
                imageAssets: [String: ClipboardCloudImageAsset] = [:],
                fileAssets: [String: ClipboardCloudFileAsset] = [:]) {
        self.changes = changes
        self.token = token
        self.moreComing = moreComing
        self.imageAssets = imageAssets
        self.fileAssets = fileAssets
    }
}

/// Testable adapter seam. The eventual CKDatabase implementation must use a
/// user's private zone, authenticate via supported Apple APIs, and provide
/// bounded, idempotent upload acknowledgements and incremental pages.
public protocol ClipboardCloudTransport: Sendable {
    /// Transport must re-check a dynamic current authorization before every
    /// separate server write, including after any intervening awaited reads.
    func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck]
    func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage
}

public enum ClipboardCloudSyncError: Error, Sendable {
    case invalidZone, consentRequired, unauthorizedContents
    case unexpectedAcknowledgement, oversizedPage
}

public struct ClipboardCloudSyncReport: Sendable, Equatable {
    public let enabled: Bool
    public let uploaded: Int
    public let downloaded: Int
    public let pending: Int
    public let moreComing: Bool

    public static let disabled = ClipboardCloudSyncReport(
        enabled: false, uploaded: 0, downloaded: 0, pending: 0, moreComing: false
    )
}

public extension ClipboardCloudConsent {
    /// Recheck current privacy preferences immediately before both outgoing
    /// and incoming work. A queued record created under old, broader consent
    /// must NOT be silently uploaded after permissions are narrowed.
    func permits(_ record: ClipboardCloudRecord) -> Bool {
        guard enabled else { return false }
        guard !record.isDeleted else { return record.payload == nil }
        guard let payload = record.payload else { return false }
        switch payload {
        case .operation(let operation):
            if !includeText && operation.text != nil { return false }
            if !includeImages && operation.image != nil { return false }
            if !includeFiles && operation.file != nil { return false }
            for item in operation.items {
                if !includeNames && item.name != nil { return false }
                if !includePaths && item.path != nil { return false }
            }
            return true
        case .collection:
            // A user-defined collection name is itself potentially private.
            return includeNames
        case .membership:
            return true
        }
    }
}

/// Serializes one explicit sync attempt. There are no timers, background
/// uploads or CloudKit account accesses in this type. Privacy defaults off;
/// the caller must present a current, explicit consent for every attempt.
public actor ClipboardCloudSyncCoordinator {
    private let journal: ClipboardCloudJournal
    private let transport: any ClipboardCloudTransport
    private let zoneID: String

    public init(journal: ClipboardCloudJournal, transport: any ClipboardCloudTransport,
                zoneID: String) throws {
        guard !zoneID.isEmpty, zoneID.utf8.count <= 180 else {
            throw ClipboardCloudSyncError.invalidZone
        }
        self.journal = journal
        self.transport = transport
        self.zoneID = zoneID
    }

    /// Compatibility entrypoint for offline tests and fixed-consent callers.
    /// Native user-facing clients should use the provider form below so
    /// changes made while awaiting the network are respected.
    public func syncOnce(
        consent: ClipboardCloudConsent
    ) async throws -> ClipboardCloudSyncReport {
        try await syncOnce(consentProvider: { consent })
    }

    /// A single bounded pass: fetch, validate and merge the remote page
    /// BEFORE uploading only after the backlog is drained. Re-read current
    /// authorization after every network suspension and directly before
    /// starting the outbound batch; the transport also verifies authorization
    /// immediately before each separate CloudKit write. A request already
    /// submitted to Apple cannot be unsent, but revocation prevents later
    /// individual server writes and local remote-data import.
    public func syncOnce(
        consentProvider: @escaping @Sendable () async -> ClipboardCloudConsent
    ) async throws -> ClipboardCloudSyncReport {
        let initial = await consentProvider()
        guard initial.enabled else { return .disabled }

        // Verify queued outbound consent before making any network call.
        // A permission revocation must not accidentally upload stale bodies.
        let queued = try journal.pending(limit: 100)
        guard queued.allSatisfy({ initial.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }

        // Fetch first to reconcile stale local logical revisions. Never
        // upload until all incremental pages have reached this Mac.
        let token = try journal.token(forZone: zoneID)
        let page = try await transport.fetch(after: token)
        try Task.checkCancellation()
        // The user may have toggled off sync or individual content categories
        // while waiting for CloudKit. Never import private content after a
        // revocation; leave the prior change token so replay is safe.
        let afterFetch = await consentProvider()
        guard afterFetch.enabled else {
            throw ClipboardCloudSyncError.consentRequired
        }
        guard page.changes.count <= 200 else {
            throw ClipboardCloudSyncError.oversizedPage
        }
        guard page.changes.allSatisfy({ afterFetch.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }
        let downloaded = try journal.applyRemote(
            page.changes, zoneID: zoneID, changeToken: page.token,
            imageAssets: page.imageAssets, fileAssets: page.fileAssets
        )
        if page.moreComing {
            return ClipboardCloudSyncReport(
                enabled: true, uploaded: 0, downloaded: downloaded,
                pending: try journal.pendingCount(), moreComing: true
            )
        }

        let pending = try journal.pending(limit: 100)
        let beforeUpload = await consentProvider()
        guard beforeUpload.enabled else {
            throw ClipboardCloudSyncError.consentRequired
        }
        guard pending.allSatisfy({ beforeUpload.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }
        let acknowledgements: [ClipboardCloudUploadAck]
        if pending.isEmpty {
            acknowledgements = []
        } else {
            acknowledgements = try await transport.upload(
                pending, permissionCheck: { record in
                    let live = await consentProvider()
                    return live.permits(record)
                }
            )
        }
        let expected = Set(pending.map {
            ClipboardCloudUploadAck(id: $0.id, mutationID: $0.mutationID)
        })
        guard acknowledgements.allSatisfy({ expected.contains($0) }) else {
            throw ClipboardCloudSyncError.unexpectedAcknowledgement
        }
        var uploaded = 0
        for acknowledgement in Set(acknowledgements) {
            if try journal.acknowledgeUploaded(
                id: acknowledgement.id,
                mutationID: acknowledgement.mutationID
            ) {
                uploaded += 1
            }
        }
        return ClipboardCloudSyncReport(
            enabled: true, uploaded: uploaded, downloaded: downloaded,
            pending: try journal.pendingCount(), moreComing: false
        )
    }
}


// MARK: - iCloud Drive folder transport (CloudKit-free build path)
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

