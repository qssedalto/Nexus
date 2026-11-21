import CloudKit
import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudKitCodecTests: XCTestCase {
    private let zone = CKRecordZone.ID(
        zoneName: "NexusClipboard", ownerName: CKCurrentUserDefaultName
    )

    private func collectionChange() -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID("c-1"), kind: .collection,
            revision: ClipboardCloudRevision(counter: 4, deviceID: "Mac-A"),
            payload: .collection(ClipboardCloudCollection(name: "重要收藏"))
        )
    }

    func testCKRecordRoundTripRetainsIdentityAndVersion() throws {
        let change = collectionChange()
        let encoded = try ClipboardCloudKitCodec.encode(change, zoneID: zone)
        XCTAssertEqual(encoded.recordID.recordName, change.id)
        XCTAssertEqual(encoded.recordID.zoneID, zone)
        XCTAssertEqual(encoded.recordType, ClipboardCloudKitCodec.recordType)
        let decoded = try ClipboardCloudKitCodec.decode(encoded, expectedZoneID: zone)
        XCTAssertEqual(decoded, change)
    }

    func testCloudKitEnvelopeCannotSilentlyChangeIdentityOrKind() throws {
        let original = collectionChange()
        let wrongKind = try ClipboardCloudKitCodec.encode(original, zoneID: zone)
        wrongKind["kind"] = "operation" as NSString
        XCTAssertThrowsError(
            try ClipboardCloudKitCodec.decode(wrongKind, expectedZoneID: zone)
        )
        let wrongSchema = try ClipboardCloudKitCodec.encode(original, zoneID: zone)
        wrongSchema["schemaVersion"] = NSNumber(value: 2)
        XCTAssertThrowsError(
            try ClipboardCloudKitCodec.decode(wrongSchema, expectedZoneID: zone)
        )
        let encoded = try ClipboardCloudKitCodec.encode(original, zoneID: zone)
        let differentZone = CKRecordZone.ID(
            zoneName: "NotNexusClipboard", ownerName: CKCurrentUserDefaultName
        )
        XCTAssertThrowsError(
            try ClipboardCloudKitCodec.decode(encoded, expectedZoneID: differentZone)
        )
    }

    func testPayloadFreeDeletionNeverRetainsCollectionName() throws {
        let original = collectionChange()
        let deletion = original.tombstone(
            revision: ClipboardCloudRevision(counter: 5, deviceID: "Mac-B")
        )
        let encoded = try ClipboardCloudKitCodec.encode(deletion, zoneID: zone)
        let document = try XCTUnwrap(encoded["document"] as? Data)
        XCTAssertFalse(String(decoding: document, as: UTF8.self).contains("重要收藏"))
        XCTAssertEqual(
            try ClipboardCloudKitCodec.decode(encoded, expectedZoneID: zone),
            deletion
        )
    }

    func testCorruptedAndOversizedPayloadAreRejected() throws {
        let record = try ClipboardCloudKitCodec.encode(collectionChange(), zoneID: zone)
        record["document"] = Data("not JSON".utf8) as NSData
        XCTAssertThrowsError(
            try ClipboardCloudKitCodec.decode(record, expectedZoneID: zone)
        )
        record["document"] = Data(repeating: 7, count: 256 * 1024 + 1) as NSData
        XCTAssertThrowsError(
            try ClipboardCloudKitCodec.decode(record, expectedZoneID: zone)
        )
    }
}
