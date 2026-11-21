import Foundation

/// Wire protocol for copy operations. The server stores metadata only unless
/// the user explicitly authorizes source paths or clipboard text separately.
public struct SyncOperationItem: Codable, Sendable, Equatable {
    public let position: Int
    public let name: String
    public let source: String?
    public let fileExtension: String?
    public let kind: String
    public let size: Int64?

    public init(position: Int, item: RecordedItem, includePaths: Bool) {
        self.position = position
        name = item.name
        source = includePaths ? item.source : nil
        fileExtension = item.fileExtension
        kind = item.kind
        size = item.size
    }

    enum CodingKeys: String, CodingKey {
        case position, name, source, kind, size
        case fileExtension = "extension"
    }
}

public struct SyncOperation: Codable, Sendable, Equatable {
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
    public let items: [SyncOperationItem]

    public init(record: RecordedOperation, includePaths: Bool, includeText: Bool) {
        id = record.id
        type = record.type
        eventTimeMS = record.eventTimeMS
        detectedTimeMS = record.detectedTimeMS
        completedTimeMS = record.completedTimeMS
        sourceApplication = record.sourceApplication
        detectionMethod = record.detectionMethod
        status = record.status
        target = includePaths ? record.target : nil
        durationMS = record.durationMS
        clipboardText = includeText ? record.clipboardText : nil
        items = record.items.enumerated().map {
            SyncOperationItem(position: $0.offset, item: $0.element, includePaths: includePaths)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, status, target, items
        case eventTimeMS = "event_time_ms"
        case detectedTimeMS = "detected_time_ms"
        case completedTimeMS = "completed_time_ms"
        case sourceApplication = "source_application"
        case detectionMethod = "detection_method"
        case durationMS = "duration_ms"
        case clipboardText = "clipboard_text"
    }
}

public struct OperationSyncBatch: Codable, Sendable {
    public let schemaVersion: Int
    public let deviceID: String
    public let operations: [SyncOperation]

    public init(deviceID: String, operations: [SyncOperation]) {
        schemaVersion = 1
        self.deviceID = deviceID
        self.operations = operations
    }

    enum CodingKeys: String, CodingKey {
        case operations
        case schemaVersion = "schema_version"
        case deviceID = "device_id"
    }
}

public struct OperationSyncConfirmation: Codable, Sendable {
    public let acceptedIDs: [String]
    enum CodingKeys: String, CodingKey { case acceptedIDs = "accepted_ids" }
}

public struct RemoteOperationRecord: Codable, Sendable {
    public let deviceID: String
    public let operation: SyncOperation
    enum CodingKeys: String, CodingKey { case operation; case deviceID = "device_id" }
}

public struct RemoteOperationPage: Codable, Sendable {
    public let operations: [RemoteOperationRecord]
    public let nextOffset: Int?
    enum CodingKeys: String, CodingKey { case operations; case nextOffset = "next_offset" }
}
