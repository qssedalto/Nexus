import Foundation

/// Plain, user-openable copies alongside the separate encrypted sync index.
/// File bytes are streamed into an unpublished temporary directory; a completed
/// copy becomes visible only after its entire tree has been written.
public enum ClipboardFolderMirror {
    public enum Content: Sendable {
        case files([URL])
        case text(String)
        case richText(text: String, rtf: Data)
        case image(Data, extensionName: String)
    }

    public enum MirrorError: Error {
        case empty, invalidSource, cancelled
    }

    private static let chunkBytes = 1_048_576

    @discardableResult
    public static func save(
        _ content: Content, to folder: URL, id: UUID = UUID(),
        cancelled: () -> Bool = { false },
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) throws -> URL {
        guard !cancelled() else { throw MirrorError.cancelled }
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "Copy \(stamp) \(id.uuidString.prefix(8))"
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        let temporary = folder.appendingPathComponent(".\(id.uuidString).partial", isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path),
              !fileManager.fileExists(atPath: temporary.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        // Validate all top-level sources before publishing any output. A
        // source equal to, or containing, our temp folder would recurse.
        var totalBytes: Int64 = 0
        switch content {
        case .files(let urls):
            guard !urls.isEmpty else { throw MirrorError.empty }
            let temporaryPath = temporary.standardizedFileURL.resolvingSymlinksInPath().path
            for url in urls {
                guard url.isFileURL else { throw MirrorError.invalidSource }
                let source = url.standardizedFileURL.resolvingSymlinksInPath().path
                let prefix = source.hasSuffix("/") ? source : source + "/"
                guard temporaryPath != source, !temporaryPath.hasPrefix(prefix) else {
                    throw MirrorError.invalidSource
                }
                totalBytes = try totalSize(of: url, fileManager: fileManager,
                                           cancelled: cancelled, current: totalBytes)
            }
        case .text(let value):
            guard !value.isEmpty else { throw MirrorError.empty }
            totalBytes = Int64(value.utf8.count)
        case .richText(let text, let rtf):
            guard !text.isEmpty, !rtf.isEmpty else { throw MirrorError.empty }
            let (sum, overflow) = Int64(text.utf8.count).addingReportingOverflow(Int64(rtf.count))
            if overflow { throw CocoaError(.fileReadTooLarge) }
            totalBytes = sum
        case .image(let data, _):
            guard !data.isEmpty else { throw MirrorError.empty }
            totalBytes = Int64(data.count)
        }

        guard !cancelled() else { throw MirrorError.cancelled }
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: temporary) } }
        var completedBytes: Int64 = 0
        switch content {
        case .files(let urls):
            for (index, url) in urls.enumerated() {
                guard !cancelled() else { throw MirrorError.cancelled }
                let base = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
                let target = temporary.appendingPathComponent("\(index + 1) \(base)")
                try copyTree(from: url, to: target, fileManager: fileManager,
                             cancelled: cancelled, copied: &completedBytes,
                             total: totalBytes, progress: progress)
            }
        case .text(let value):
            guard !cancelled() else { throw MirrorError.cancelled }
            try value.write(to: temporary.appendingPathComponent("Text.txt"),
                            atomically: true, encoding: .utf8)
            completedBytes = totalBytes
            progress(completedBytes, totalBytes)
        case .richText(let text, let rtf):
            guard !cancelled() else { throw MirrorError.cancelled }
            try text.write(to: temporary.appendingPathComponent("Text.txt"),
                           atomically: true, encoding: .utf8)
            completedBytes = Int64(text.utf8.count)
            progress(completedBytes, totalBytes)
            guard !cancelled() else { throw MirrorError.cancelled }
            // Public RTF bytes preserve styling and fonts where supported.
            // Always include plain text for applications without RTF support.
            try rtf.write(to: temporary.appendingPathComponent("Rich Text.rtf"),
                          options: .atomic)
            completedBytes = totalBytes
            progress(completedBytes, totalBytes)
        case .image(let data, let ext):
            guard !cancelled() else { throw MirrorError.cancelled }
            let safeExtension = ["png", "tiff", "jpeg", "heic", "gif"].contains(ext) ? ext : "png"
            try data.write(to: temporary.appendingPathComponent("Image.\(safeExtension)"),
                           options: .atomic)
            completedBytes = totalBytes
            progress(completedBytes, totalBytes)
        }
        guard !cancelled() else { throw MirrorError.cancelled }
        try fileManager.moveItem(at: temporary, to: destination)
        committed = true
        return destination
    }

    /// Counts regular-file data, not directory metadata or symbolic-link
    /// targets. Walks the directory lazily so very large trees remain bounded.
    private static func totalSize(
        of source: URL, fileManager: FileManager, cancelled: () -> Bool,
        current: Int64 = 0
    ) throws -> Int64 {
        guard !cancelled() else { throw MirrorError.cancelled }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink: return current
        case .typeDirectory:
            var result = current
            for child in try fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil, options: []
            ) {
                result = try totalSize(of: child, fileManager: fileManager,
                                       cancelled: cancelled, current: result)
            }
            return result
        case .typeRegular:
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let (sum, overflow) = current.addingReportingOverflow(max(0, size))
            if overflow { throw CocoaError(.fileReadTooLarge) }
            return sum
        default:
            throw MirrorError.invalidSource
        }
    }

    /// A 1 MiB streaming copy can be cancelled while a single large file
    /// is in progress. No file bytes are buffered into a giant Data value.
    private static func copyTree(
        from source: URL, to target: URL, fileManager: FileManager,
        cancelled: () -> Bool, copied: inout Int64, total: Int64,
        progress: @Sendable (Int64, Int64) -> Void
    ) throws {
        guard !cancelled() else { throw MirrorError.cancelled }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink:
            // Preserve the link itself; never recurse into its target.
            try fileManager.copyItem(at: source, to: target)
        case .typeDirectory:
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil, options: []
            ) {
                try copyTree(from: child,
                             to: target.appendingPathComponent(child.lastPathComponent),
                             fileManager: fileManager, cancelled: cancelled,
                             copied: &copied, total: total, progress: progress)
            }
            try preserveBasicAttributes(attributes, at: target, fileManager: fileManager)
        case .typeRegular:
            guard fileManager.createFile(atPath: target.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: target)
            defer { try? writer.close() }
            var lastReported: Int64 = copied
            while true {
                guard !cancelled() else { throw MirrorError.cancelled }
                let chunk = try reader.read(upToCount: chunkBytes) ?? Data()
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if copied - lastReported >= 4 * Int64(chunkBytes) || copied >= total {
                    progress(copied, total)
                    lastReported = copied
                }
            }
            // Close the output before applying metadata to its final bytes.
            try writer.close()
            try preserveBasicAttributes(attributes, at: target, fileManager: fileManager)
        default:
            throw MirrorError.invalidSource
        }
    }

    private static func preserveBasicAttributes(
        _ source: [FileAttributeKey: Any], at target: URL,
        fileManager: FileManager
    ) throws {
        var copy: [FileAttributeKey: Any] = [:]
        for key: FileAttributeKey in [.posixPermissions, .modificationDate, .creationDate] {
            if let value = source[key] { copy[key] = value }
        }
        if !copy.isEmpty { try fileManager.setAttributes(copy, ofItemAtPath: target.path) }
    }
}