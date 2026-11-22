import Foundation

/// Plain, user-openable copies alongside the separate encrypted sync index.
/// Every copy gets a unique visible directory; source files are copied by the
/// file system without loading their bytes into the app.
public enum ClipboardFolderMirror {
    public enum Content: Sendable {
        case files([URL])
        case text(String)
        case image(Data, extensionName: String)
    }

    public enum MirrorError: Error {
        case empty, invalidSource, cancelled
    }

    @discardableResult
    public static func save(
        _ content: Content, to folder: URL, id: UUID = UUID(),
        cancelled: () -> Bool = { false }
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
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: temporary) } }
        switch content {
        case .files(let urls):
            guard !urls.isEmpty else { throw MirrorError.empty }
            for (index, url) in urls.enumerated() {
                guard !cancelled() else { throw MirrorError.cancelled }
                guard url.isFileURL, fileManager.fileExists(atPath: url.path) else {
                    throw MirrorError.invalidSource
                }
                // Prevent copying the selected folder (or an ancestor) into
                // a newly created descendant. Resolve aliases before checking.
                let sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path
                let temporaryPath = temporary.standardizedFileURL.resolvingSymlinksInPath().path
                let descendantPrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
                guard temporaryPath != sourcePath,
                      !temporaryPath.hasPrefix(descendantPrefix) else {
                    throw MirrorError.invalidSource
                }
                let base = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
                let target = temporary.appendingPathComponent("\(index + 1) \(base)")
                try fileManager.copyItem(at: url, to: target)
            }
        case .text(let value):
            guard !value.isEmpty else { throw MirrorError.empty }
            try value.write(to: temporary.appendingPathComponent("Text.txt"),
                            atomically: true, encoding: .utf8)
        case .image(let data, let ext):
            guard !data.isEmpty else { throw MirrorError.empty }
            let safeExtension = ["png", "tiff", "jpeg", "heic", "gif"].contains(ext) ? ext : "png"
            try data.write(to: temporary.appendingPathComponent("Image.\(safeExtension)"), options: .atomic)
        }
        guard !cancelled() else { throw MirrorError.cancelled }
        try fileManager.moveItem(at: temporary, to: destination)
        committed = true
        return destination
    }
}
