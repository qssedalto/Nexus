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

    /// Redact any fields not authorized for a remote restore, even when a
    /// server responds with a more permissive historical record.
    public func redacted(includePaths: Bool) -> SyncOperationItem {
        SyncOperationItem(
            position: position, name: name,
            source: includePaths ? source : nil,
            fileExtension: fileExtension, kind: kind, size: size
        )
    }

    private init(position: Int, name: String, source: String?,
                 fileExtension: String?, kind: String, size: Int64?) {
        self.position = position
        self.name = name
        self.source = source
        self.fileExtension = fileExtension
        self.kind = kind
        self.size = size
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

    /// Reapply local permissions to data returned from the server. A remote
    /// backup may contain paths or clipboard text from an earlier session.
    public func redacted(includePaths: Bool, includeText: Bool) -> SyncOperation {
        SyncOperation(
            id: id, type: type, eventTimeMS: eventTimeMS,
            detectedTimeMS: detectedTimeMS, completedTimeMS: completedTimeMS,
            sourceApplication: sourceApplication, detectionMethod: detectionMethod,
            status: status, target: includePaths ? target : nil,
            durationMS: durationMS,
            clipboardText: includeText ? clipboardText : nil,
            items: items.map { $0.redacted(includePaths: includePaths) }
        )
    }

    private init(id: String, type: String, eventTimeMS: Int64?,
                 detectedTimeMS: Int64, completedTimeMS: Int64?,
                 sourceApplication: String?, detectionMethod: String,
                 status: String, target: String?, durationMS: Int64?,
                 clipboardText: String?, items: [SyncOperationItem]) {
        self.id = id
        self.type = type
        self.eventTimeMS = eventTimeMS
        self.detectedTimeMS = detectedTimeMS
        self.completedTimeMS = completedTimeMS
        self.sourceApplication = sourceApplication
        self.detectionMethod = detectionMethod
        self.status = status
        self.target = target
        self.durationMS = durationMS
        self.clipboardText = clipboardText
        self.items = items
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

    public func redacted(includePaths: Bool, includeText: Bool) -> RemoteOperationRecord {
        RemoteOperationRecord(
            deviceID: deviceID,
            operation: operation.redacted(includePaths: includePaths, includeText: includeText)
        )
    }

    private init(deviceID: String, operation: SyncOperation) {
        self.deviceID = deviceID
        self.operation = operation
    }

    enum CodingKeys: String, CodingKey { case operation; case deviceID = "device_id" }
}

public struct RemoteOperationPage: Codable, Sendable {
    public let operations: [RemoteOperationRecord]
    public let nextOffset: Int?
    enum CodingKeys: String, CodingKey { case operations; case nextOffset = "next_offset" }
}
