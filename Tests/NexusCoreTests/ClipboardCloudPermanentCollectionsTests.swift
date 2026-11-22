import Foundation
import XCTest
@testable import NexusCore

final class ClipboardCloudPermanentCollectionsTests: XCTestCase {
    private func setupStores() throws -> (
        OperationStore, OperationStore, ClipboardCloudJournal, URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = try OperationStore(
            url: root.appendingPathComponent("source.sqlite")
        )
        let destination = try OperationStore(
            url: root.appendingPathComponent("destination.sqlite")
        )
        let journal = try ClipboardCloudJournal(
            url: root.appendingPathComponent("cloud.sqlite")
        )
        return (source, destination, journal, root)
    }

    func testCloudCollectionAndOrderedMembersRestoreWithoutEchoOrDuplicates() throws {
        let (source, target, journal, root) = try setupStores()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...2 {
            try source.record(
                type: "text_copy", urls: [], sourceApplication: nil,
                detectionMethod: "clipboard",
                detectedTimeMS: Int64(index),
                clipboardText: "小组代码 \(index)"
            )
        }
        let ids = try source.query(from: 0, to: 10).map(\.id)
        let collection = try source.createCollection(named: "统计作业")
        XCTAssertTrue(try source.addOperation(id: ids[0], toCollection: collection.id))
        XCTAssertTrue(try source.addOperation(id: ids[1], toCollection: collection.id))
        let consent = ClipboardCloudConsent(
            enabled: true, includeText: true, includeNames: true
        )
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal, deviceID: "Mac-A", consent: consent
        )
        XCTAssertEqual(try ClipboardCloudLocalSnapshot.stageCollections(
            from: source, in: journal, deviceID: "Mac-A", consent: consent), 3)
        let records = try journal.pending(limit: 100)
        XCTAssertEqual(try target.importCloudHistory(records, consent: consent), 2)
        XCTAssertEqual(try target.importCloudCollections(records, consent: consent), 3)
        XCTAssertEqual(try target.importCloudCollections(records, consent: consent), 0)
        let mirrors = try target.listCollections()
        XCTAssertEqual(mirrors.count, 1)
        let mirror = try XCTUnwrap(mirrors.first)
        XCTAssertEqual(mirror.id, "cloudkit:" + collection.id)
        XCTAssertTrue(mirror.name.contains("统计作业"))
        XCTAssertEqual(
            try target.collectionOperationIDs(collectionID: mirror.id),
            ids.map { "cloudkit:" + $0 }
        )
        // A mirror must never become a new outbound cloud collection.
        let destinationJournal = try ClipboardCloudJournal(
            url: root.appendingPathComponent("target-cloud.sqlite")
        )
        XCTAssertEqual(try ClipboardCloudLocalSnapshot.stageCollections(
            from: target, in: destinationJournal,
            deviceID: "Mac-B", consent: consent
        ), 0)
    }

    func testCloudTombstoneDeletesOnlyMirrorNotUserCreatedCollection() throws {
        let (source, target, journal, root) = try setupStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try target.createCollection(named: "我的本地收藏")
        let remote = try source.createCollection(named: "跨设备收藏")
        let consent = ClipboardCloudConsent(enabled: true, includeNames: true)
        _ = try ClipboardCloudLocalSnapshot.stageCollections(
            from: source, in: journal, deviceID: "Mac-A", consent: consent
        )
        let record = try XCTUnwrap(try journal.pending().first {
            $0.id == ClipboardCloudRecord.collectionID(remote.id)
        })
        XCTAssertEqual(try target.importCloudCollections([record], consent: consent), 1)
        let tombstone = record.tombstone(
            revision: ClipboardCloudRevision(counter: 2, deviceID: "Mac-B")
        )
        XCTAssertEqual(try target.importCloudCollections([tombstone], consent: consent), 1)
        XCTAssertEqual(try target.listCollections().map(\.id), [local.id])
    }

    func testRevokedNamesAndInvalidMembershipCannotPartiallyImport() throws {
        let (_, target, _, root) = try setupStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let col = UUID().uuidString
        let op = UUID().uuidString
        let revision = ClipboardCloudRevision(counter: 1, deviceID: "Mac-A")
        let valid = ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(col), kind: .collection,
            revision: revision,
            payload: .collection(ClipboardCloudCollection(name: "Remote"))
        )
        let malformedMembership = ClipboardCloudRecord(
            id: ClipboardCloudRecord.membershipID(
                collectionID: col, operationID: op
            ), kind: .membership, revision: revision,
            payload: .membership(ClipboardCloudMembership(
                collectionID: col, operationID: op, sortPosition: -1
            ))
        )
        XCTAssertEqual(try target.importCloudCollections(
            [valid], consent: .init()
        ), 0)
        XCTAssertThrowsError(try target.importCloudCollections(
            [valid, malformedMembership],
            consent: .init(enabled: true, includeNames: true)
        ))
        XCTAssertTrue(try target.listCollections().isEmpty)
    }
}
