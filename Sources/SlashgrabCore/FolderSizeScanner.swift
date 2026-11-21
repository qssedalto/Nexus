import Foundation

/// Explicit, cancellable background-only directory size estimation.
///
/// It is deliberately never invoked from Finder Sync, URL metadata collection,
/// pasteboard polling, or a SwiftUI view's body. The caller has to initiate
/// this scan. It measures logical regular-file sizes; symlink targets are not
/// followed. A partial/error result is never returned as a complete size.
public enum FolderSizeScanner {
    public enum ScanError: LocalizedError {
        case invalidDirectory, unavailable, itemLimitExceeded, deadlineExceeded

        public var errorDescription: String? {
            switch self {
            case .invalidDirectory: "Only local directories and packages can be measured"
            case .unavailable: "Folder contents could not be completely enumerated"
            case .itemLimitExceeded: "Folder exceeded the scan item safety limit"
            case .deadlineExceeded: "Folder scan exceeded the time safety limit"
            }
        }
    }

    public static func logicalSize(
        of source: URL,
        maxEntries: Int = 500_000,
        maxDuration: TimeInterval = 60
    ) throws -> Int64 {
        try Task<Never, Never>.checkCancellation()
        guard source.isFileURL else { throw ScanError.invalidDirectory }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey,
            .isSymbolicLinkKey, .fileSizeKey
        ]
        let top = try source.resourceValues(forKeys: keys)
        guard top.isDirectory == true, top.isSymbolicLink != true else {
            throw ScanError.invalidDirectory
        }

        let started = Date()
        var encounteredError = false
        let walker = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return false
            }
        )
        guard let walker else { throw ScanError.unavailable }

        var total: Int64 = 0
        var visited = 0
        while let url = walker.nextObject() as? URL {
            try Task<Never, Never>.checkCancellation()
            visited += 1
            guard visited <= maxEntries else { throw ScanError.itemLimitExceeded }
            guard Date().timeIntervalSince(started) <= maxDuration else {
                throw ScanError.deadlineExceeded
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let bytes = values.fileSize, bytes >= 0 else { throw ScanError.unavailable }
            let (value, overflow) = total.addingReportingOverflow(Int64(bytes))
            guard !overflow else { throw ScanError.unavailable }
            total = value
        }
        guard !encounteredError else { throw ScanError.unavailable }
        return total
    }
}
