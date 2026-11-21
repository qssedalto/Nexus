import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudLocalSnapshotTests: XCTestCase {
    private func makeStores() throws -> (OperationStore, ClipboardCloudJournal, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let operations = try OperationStore(url: root.appendingPathComponent("ops.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("cloud.sqlite"))
        return (operations, journal, root)
    }

    func testOptInStagesPagesOnceWithoutRequeueingIdenticalHistory() throws {
        let (store, journal, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<5 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard", detectedTimeMS: Int64(index + 1),
                             clipboardText: "中文 snippet \(index)")
        }
        let disabled = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "Mac-A", consent: .init())
        XCTAssertEqual(disabled.staged, 0)
        XCTAssertEqual(try journal.pendingCount(), 0)
        let consent = ClipboardCloudConsent(enabled: true, includeText: true)
        let first = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "Mac-A", consent: consent,
            limit: 2)
        XCTAssertEqual(first.staged, 2)
        XCTAssertEqual(first.nextOffset, 2)
        let retry = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "Mac-A", consent: consent,
            limit: 2)
        XCTAssertEqual(retry.staged, 0)
        XCTAssertEqual(try journal.pendingCount(), 2)
        var offset = try XCTUnwrap(first.nextOffset)
        while true {
            let page = try ClipboardCloudLocalSnapshot.stagePage(
                from: store, in: journal, deviceID: "Mac-A",
                consent: consent, offset: offset, limit: 2)
            if let next = page.nextOffset { offset = next } else { break }
        }
        XCTAssertEqual(try journal.pendingCount(), 5)
        let redacted = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "Mac-A",
            consent: .init(enabled: true), limit: 2)
        XCTAssertEqual(redacted.staged, 2)
        let firstRecord = try XCTUnwrap(journal.pending().first {
            $0.id.hasPrefix("operation:")
        })
        if case .operation(let payload)? = firstRecord.payload {
            XCTAssertNil(payload.text)
        } else {
            XCTFail("Expected an operation")
        }
    }

    func testManualCollectionStageIsStableAndMembershipOrderIsPreserved() throws {
        let (store, journal, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 1,
                         clipboardText: "one")
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 2,
                         clipboardText: "two")
        let ids = try store.query(from: 0, to: 3).map(\.id)
        let collection = try store.createCollection(named: "Study")
        XCTAssertTrue(try store.addOperation(id: ids[0], toCollection: collection.id))
        XCTAssertTrue(try store.addOperation(id: ids[1], toCollection: collection.id))
        let consent = ClipboardCloudConsent(enabled: true, includeNames: true)
        XCTAssertEqual(try ClipboardCloudLocalSnapshot.stageCollections(
            from: store, in: journal, deviceID: "Mac-A", consent: consent), 3)
        XCTAssertEqual(try ClipboardCloudLocalSnapshot.stageCollections(
            from: store, in: journal, deviceID: "Mac-A", consent: consent), 0)
        XCTAssertEqual(try journal.pendingCount(), 3)
        let entry = try XCTUnwrap(journal.record(
            id: ClipboardCloudRecord.membershipID(
                collectionID: collection.id, operationID: ids[0])
        ))
        if case .membership(let member)? = entry.payload {
            XCTAssertEqual(member.sortPosition, 0)
        } else {
            XCTFail("Expected collection membership")
        }
    }

    func testSuccessfulLocalDeletionEnqueuesPayloadFreeTombstone() throws {
        let (store, journal, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 42,
                         clipboardText: "do not retain this")
        let id = try XCTUnwrap(store.query(from: 0, to: 50).first?.id)
        let consent = ClipboardCloudConsent(enabled: true, includeText: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "Mac-A", consent: consent)
        XCTAssertTrue(try store.deleteOperation(id: id))
        XCTAssertTrue(try ClipboardCloudLocalSnapshot.stageDeletion(
            localOperationID: id, in: journal, deviceID: "Mac-A",
            consent: .init(enabled: true)))
        let deletion = try XCTUnwrap(journal.record(
            id: ClipboardCloudRecord.operationID(id)
        ))
        XCTAssertTrue(deletion.isDeleted)
        XCTAssertNil(deletion.payload)
        XCTAssertFalse(try ClipboardCloudLocalSnapshot.stageDeletion(
            localOperationID: id, in: journal, deviceID: "Mac-A",
            consent: .init(enabled: true)))
    }
}
