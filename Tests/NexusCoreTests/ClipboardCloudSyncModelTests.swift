import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudSyncModelTests: XCTestCase {
    private func revision(_ counter: Int64, _ device: String) -> ClipboardCloudRevision {
        ClipboardCloudRevision(counter: counter, deviceID: device)
    }

    private func live(_ id: String, _ counter: Int64, _ device: String,
                      mutationID: String = "11111111-1111-4111-8111-111111111111"
    ) -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(id), kind: .collection,
            revision: revision(counter, device), mutationID: mutationID,
            payload: .collection(ClipboardCloudCollection(name: "Saved"))
        )
    }

    func testExplicitConsentNeverSilentlyExportsPathsOrText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "text_copy", urls: [],
                         sourceApplication: "com.apple.Safari",
                         detectionMethod: "clipboard", detectedTimeMS: 1000,
                         clipboardText: "私人剪贴板内容")
        try store.record(type: "copy",
                         urls: [URL(fileURLWithPath: "/Users/private/秘密文件.pdf")],
                         sourceApplication: nil, detectionMethod: "clipboard",
                         detectedTimeMS: 1001)
        let entries = try store.query(from: 0, to: 2000)
        let textEntry = try XCTUnwrap(entries.first(where: { $0.type == "text_copy" }))
        let fileEntry = try XCTUnwrap(entries.first(where: { $0.type == "copy" }))
        XCTAssertNil(ClipboardCloudOperation(record: textEntry, consent: .init()))
        let metadata = try XCTUnwrap(ClipboardCloudOperation(
            record: textEntry, consent: .init(enabled: true)))
        XCTAssertNil(metadata.text)
        XCTAssertNil(metadata.items[0].name)
        XCTAssertNil(metadata.items[0].path)
        let fileMetadata = try XCTUnwrap(ClipboardCloudOperation(
            record: fileEntry, consent: .init(enabled: true)))
        XCTAssertNil(fileMetadata.items[0].name)
        XCTAssertNil(fileMetadata.items[0].path)
        let explicit = try XCTUnwrap(ClipboardCloudOperation(
            record: fileEntry, consent: .init(enabled: true, includeNames: true,
                                             includePaths: true)))
        XCTAssertEqual(explicit.items[0].name, "秘密文件.pdf")
        XCTAssertEqual(explicit.items[0].path, "/Users/private/秘密文件.pdf")
        let explicitText = try XCTUnwrap(ClipboardCloudOperation(
            record: textEntry, consent: .init(enabled: true, includeText: true)))
        XCTAssertEqual(explicitText.text, "私人剪贴板内容")
        let encoded = try JSONEncoder().encode(fileMetadata)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/Users/private"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("秘密文件"))
    }

    func testLogicalRevisionsAreMonotonicDespiteDeviceClockSkew() {
        let local = revision(4, "mac-A")
        let remote = revision(15, "mac-B")
        XCTAssertEqual(ClipboardCloudRevision.next(deviceID: "mac-A",
                      after: local, observing: remote)?.counter, 16)
        XCTAssertNil(ClipboardCloudRevision.next(deviceID: "mac-A",
                     after: revision(Int64.max, "mac-B")))
    }

    func testDeletingAnEntryWinsEqualCounterAndNoOriginalPayloadSurvives() throws {
        let first = live("collection-1", 9, "mac-A")
        let deletion = first.tombstone(revision: revision(9, "mac-B"))
        XCTAssertTrue(deletion.isDeleted)
        XCTAssertNil(deletion.payload)
        XCTAssertEqual(try ClipboardCloudMerge.winner(first, deletion), deletion)
        XCTAssertEqual(try ClipboardCloudMerge.winner(deletion, first), deletion)
        // A genuinely newer local edit may re-create a record; older changes
        // must not resurrect an already deleted record.
        let future = live("collection-1", 10, "mac-A")
        XCTAssertEqual(try ClipboardCloudMerge.winner(deletion, future), future)
        XCTAssertEqual(try ClipboardCloudMerge.winner(deletion, first), deletion)
    }

    func testReplayAndDifferentDownloadOrdersProduceIdenticalResults() throws {
        let old = live("collection-1", 1, "mac-A")
        let update = live("collection-1", 3, "mac-B")
        let deletion = update.tombstone(revision: revision(3, "mac-C"))
        let other = live("collection-2", 2, "mac-A")
        let lhs = try ClipboardCloudMerge.merged(
            existing: [old, other], incoming: [update, deletion, old, deletion])
        let rhs = try ClipboardCloudMerge.merged(
            existing: [deletion, old, update], incoming: [other, old])
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.count, 2)
        XCTAssertEqual(lhs[0], deletion)
        XCTAssertEqual(try ClipboardCloudMerge.merged(existing: lhs, incoming: lhs), lhs)
    }

    func testStableMembershipAndCollectionKeysAndJSONRoundTrip() throws {
        let payload: ClipboardCloudPayload = .membership(
            ClipboardCloudMembership(collectionID: "c", operationID: "o", sortPosition: 4)
        )
        let record = ClipboardCloudRecord(
            id: ClipboardCloudRecord.membershipID(collectionID: "c", operationID: "o"),
            kind: .membership, revision: revision(2, "mac-A"), payload: payload
        )
        let batch = try ClipboardCloudBatch(
            sendingDeviceID: "mac-A", changes: [record]
        ).validated()
        let json = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardCloudBatch.self, from: json), batch)
        XCTAssertThrowsError(try ClipboardCloudBatch(
            sendingDeviceID: "", changes: [record]
        ).validated())
    }

    func testBadRecordsAndForgedConflictingMutationFailClosed() throws {
        let original = live("collection-1", 7, "mac-A")
        let forged = ClipboardCloudRecord(
            id: original.id, kind: .collection, revision: original.revision,
            mutationID: original.mutationID,
            payload: .collection(ClipboardCloudCollection(name: "Changed"))
        )
        XCTAssertThrowsError(try ClipboardCloudMerge.winner(original, forged))
        let invalid = ClipboardCloudRecord(
            id: "operation:wrong", kind: .collection,
            revision: revision(1, "mac-A"),
            payload: .collection(ClipboardCloudCollection(name: "Wrong"))
        )
        XCTAssertThrowsError(try invalid.validated())
        let badDeletion = ClipboardCloudRecord(
            id: "collection:x", kind: .collection,
            revision: revision(2, "mac-B"), isDeleted: true,
            payload: .collection(ClipboardCloudCollection(name: "Secret"))
        )
        XCTAssertThrowsError(try badDeletion.validated())
        XCTAssertThrowsError(try ClipboardCloudMerge.winner(
            original, live("different", 8, "mac-B")))
    }
}
