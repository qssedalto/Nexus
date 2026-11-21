import Foundation

/// Cross-platform projection of Nexus's persisted clipboard operation model.
/// The mobile target intentionally does not compile macOS-specific Finder,
/// input monitoring, local App Group or other platform services.
public struct RecordedItem: Sendable, Equatable {
    public let name: String
    public let source: String?
    public let fileExtension: String?
    public let kind: String
    public let size: Int64?

    public init(name: String, source: String? = nil, fileExtension: String? = nil,
                kind: String = "text", size: Int64? = nil) {
        self.name = name
        self.source = source
        self.fileExtension = fileExtension
        self.kind = kind
        self.size = size
    }
}

public struct RecordedOperation: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let eventTimeMS: Int64?
    public let detectedTimeMS: Int64
    public let completedTimeMS: Int64?
    public let sourceApplication: String?
    public let detectionMethod: String
    public let status: String
    public let target: String?
    public let durationMS: Int64?
    public let clipboardText: String?
    public let items: [RecordedItem]

    public init(id: String = UUID().uuidString, type: String = "text_copy",
                detectedTimeMS: Int64, clipboardText: String,
                items: [RecordedItem] = []) {
        self.id = id
        self.type = type
        eventTimeMS = nil
        self.detectedTimeMS = detectedTimeMS
        completedTimeMS = nil
        sourceApplication = nil
        detectionMethod = "explicit_mobile_pasteboard_import"
        status = "clipboard_detected"
        target = nil
        durationMS = nil
        self.clipboardText = clipboardText
        self.items = items.isEmpty ? [
            RecordedItem(name: "Text", kind: "text",
                         size: Int64(clipboardText.utf8.count))
        ] : items
    }
}
