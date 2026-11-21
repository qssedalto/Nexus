import CloudKit
import Foundation

/// Lossless, strictly checked CKRecord mapping for the future private CloudKit
/// zone. Pure conversion only: does not create a CKContainer, query an iCloud
/// account, request entitlement, schedule networking or upload anything.
public enum ClipboardCloudKitCodec {
    public static let recordType = "NexusClipboardChangeV1"
    public static let schemaVersion = 1
    public static let maximumDocumentBytes = 256 * 1024

    public enum CodecError: Error {
        case unsupportedRecord, wrongZone, wrongIdentity, malformedMetadata
        case invalidPayload, oversizedDocument
    }

    public static func encode(
        _ change: ClipboardCloudRecord, zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        let valid = try change.validated()
        let document = try JSONEncoder().encode(valid)
        guard document.count <= maximumDocumentBytes else {
            throw CodecError.oversizedDocument
        }
        let id = CKRecord.ID(recordName: valid.id, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: id)
        record["schemaVersion"] = NSNumber(value: schemaVersion)
        record["kind"] = valid.kind.rawValue as NSString
        record["counter"] = NSNumber(value: valid.revision.counter)
        record["deviceID"] = valid.revision.deviceID as NSString
        record["mutationID"] = valid.mutationID as NSString
        record["isDeleted"] = NSNumber(value: valid.isDeleted)
        // JSON document is locally privacy-scoped before encoding. Never
        // derive a CloudKit blob from raw pasted image pixels here.
        record["document"] = document as NSData
        return record
    }

    public static func decode(
        _ record: CKRecord, expectedZoneID: CKRecordZone.ID
    ) throws -> ClipboardCloudRecord {
        guard record.recordType == recordType else {
            throw CodecError.unsupportedRecord
        }
        guard record.recordID.zoneID == expectedZoneID else {
            throw CodecError.wrongZone
        }
        guard let version = record["schemaVersion"] as? NSNumber,
              version.intValue == schemaVersion,
              let kindRaw = record["kind"] as? String,
              let kind = ClipboardCloudKind(rawValue: kindRaw),
              let counter = record["counter"] as? NSNumber,
              let deviceID = record["deviceID"] as? String,
              let mutationID = record["mutationID"] as? String,
              let isDeleted = record["isDeleted"] as? NSNumber,
              let rawData = record["document"] as? Data else {
            throw CodecError.malformedMetadata
        }
        guard !rawData.isEmpty, rawData.count <= maximumDocumentBytes else {
            throw CodecError.oversizedDocument
        }
        let decoded: ClipboardCloudRecord
        do {
            decoded = try JSONDecoder().decode(ClipboardCloudRecord.self, from: rawData)
            _ = try decoded.validated()
        } catch {
            throw CodecError.invalidPayload
        }
        // Never trust a JSON body if the CKRecord envelope disagrees with it.
        // This prevents a malicious/wrongly mapped record from overwriting a
        // different clipboard record in the SQLite change journal.
        guard decoded.id == record.recordID.recordName else {
            throw CodecError.wrongIdentity
        }
        guard decoded.kind == kind, decoded.revision.counter == counter.int64Value,
              decoded.revision.deviceID == deviceID,
              decoded.mutationID == mutationID, decoded.isDeleted == isDeleted.boolValue else {
            throw CodecError.malformedMetadata
        }
        return decoded
    }
}
