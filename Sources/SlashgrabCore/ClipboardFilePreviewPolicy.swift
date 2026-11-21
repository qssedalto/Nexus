import Foundation

/// Conservative metadata gate for Quick Look previews. Never ask a provider
/// to hydrate cloud-only files just to populate an optional clipboard card.
public enum ClipboardFilePreviewPolicy {
    public static let maximumFileSizeBytes: Int64 = 24 * 1_024 * 1_024

    private static let previewableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff",
        "pdf", "txt", "md", "rtf", "doc", "docx", "ppt", "pptx",
        "xls", "xlsx", "swift", "py", "json", "js", "ts",
        "yaml", "yml", "html", "css", "mov", "mp4"
    ]

    /// Returns nil without reading file contents. This is intentionally
    /// conservative: iCloud-only and general CloudStorage/File Provider paths
    /// fall back to the document icon instead of triggering a download.
    public static func eligibleLocalURL(
        path: String, maximumBytes: Int64 = maximumFileSizeBytes
    ) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0"),
              maximumBytes > 0 else { return nil }
        let url = URL(fileURLWithPath: path)
        guard previewableExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }
        let components = url.standardizedFileURL.pathComponents
        if components.count > 2 {
            for index in 0..<(components.count - 1)
                where components[index] == "Library" &&
                      components[index + 1] == "CloudStorage" {
                return nil
            }
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.isPackage != true,
              let size = values.fileSize, size > 0,
              Int64(size) <= maximumBytes else {
            return nil
        }
        if values.isUbiquitousItem == true &&
           values.ubiquitousItemDownloadingStatus != .current {
            return nil
        }
        return url
    }
}
