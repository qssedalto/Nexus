import Foundation

/// Produces a small, plain-text label for the menu-bar preview of an already
/// persisted clipboard event. The menu never reads binary image/file data.
public enum ClipboardQuickMenuSummary {
    public static func title(
        for operation: RecordedOperation, maximumCharacters: Int = 48
    ) -> String {
        let maximum = max(8, min(120, maximumCharacters))
        let text: String
        switch operation.type {
        case "text_copy":
            text = operation.clipboardText ?? "Text copy"
        case "image_copy":
            text = "Copied image"
        default:
            if operation.items.count > 1 {
                text = "\(operation.items.count) copied items"
            } else {
                text = operation.items.first?.name ?? "Copied file"
            }
        }
        let normalized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Clipboard entry" }
        if normalized.count <= maximum { return normalized }
        return String(normalized.prefix(maximum - 1)) + "…"
    }

    public static func recent(
        from rows: [RecordedOperation], limit: Int = 5
    ) -> [RecordedOperation] {
        Array(rows.filter {
            ["text_copy", "copy", "path_copy", "image_copy", "drop_copy"]
                .contains($0.type)
        }.sorted {
            let left = $0.eventTimeMS ?? $0.detectedTimeMS
            let right = $1.eventTimeMS ?? $1.detectedTimeMS
            return left == right ? $0.id > $1.id : left > right
        }.prefix(max(1, min(10, limit))))
    }
}
