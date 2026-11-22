import Foundation
import XCTest
@testable import NexusCore

final class ClipboardCloudJournalTests: XCTestCase {
    private func record(_ key: String, _ counter: Int64, device: String = "mac-A",
                        name: String = "收藏") -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(key),
            kind: .collection,
            revision: ClipboardCloudRevision(counter: counter, deviceID: device),
            payload: .collection(ClipboardCloudCollection(name: name))
        )
    }

    func testOutboxPersistsAcrossRestartAndAcknowledgesOnlyExactMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.sqlite")
        let old = record("a", 1)
        do {
            let journal = try ClipboardCloudJournal(url: url)
            XCTAssertTrue(try journal.stageLocal(old))
            XCTAssertFalse(try journal.stageLocal(old))
            XCTAssertEqual(try journal.pending().map(\.id), [old.id])
            XCTAssertEqual(try journal.pendingCount(), 1)
        }
        let reopened = try ClipboardCloudJournal(url: url)
        XCTAssertEqual(try reopened.record(id: old.id), old)
        let newer = record("a", 2, name: "改名")
        XCTAssertTrue(try reopened.stageLocal(newer))
        XCTAssertFalse(try reopened.acknowledgeUploaded(
            id: old.id, mutationID: old.mutationID
        ), "An outdated ACK must never drop a newer pending edit")
        XCTAssertEqual(try reopened.pending().map(\.mutationID), [newer.mutationID])
        XCTAssertTrue(try reopened.acknowledgeUploaded(
            id: newer.id, mutationID: newer.mutationID
        ))
        XCTAssertFalse(try reopened.acknowledgeUploaded(
            id: newer.id, mutationID: newer.mutationID
        ))
        XCTAssertEqual(try reopened.pendingCount(), 0)
    }

    func testRemoteMergeAndTokenAreAtomicAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("sync.sqlite"))
        let local = record("x", 10)
        let remote = record("x", 10, device: "mac-B")
        let other = record("y", 4, device: "mac-B")
        let tombstone = remote.tombstone(
            revision: ClipboardCloudRevision(counter: 10, deviceID: "mac-C")
        )
        XCTAssertTrue(try journal.stageLocal(local))
        XCTAssertEqual(try journal.applyRemote(
            [remote, other, tombstone], zoneID: "private-zone",
            changeToken: Data([0xAA, 0xBB])
        ), 2)
        XCTAssertEqual(try journal.record(id: local.id), tombstone)
        XCTAssertEqual(try journal.pendingCount(), 0)
        XCTAssertEqual(try journal.token(forZone: "private-zone"), Data([0xAA, 0xBB]))
        XCTAssertEqual(try journal.applyRemote(
            [remote, tombstone, other], zoneID: "private-zone",
            changeToken: Data([0xAB])
        ), 0)
        XCTAssertEqual(try journal.token(forZone: "private-zone"), Data([0xAB]))

        let invalid = ClipboardCloudRecord(
            id: "collection:bad", kind: .operation,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "mac-X"),
            payload: nil
        )
        XCTAssertThrowsError(try journal.applyRemote(
            [record("z", 1), invalid], zoneID: "private-zone",
            changeToken: Data([0xFF])
        ))
        XCTAssertNil(try journal.record(id: "collection:z"))
        XCTAssertEqual(try journal.token(forZone: "private-zone"), Data([0xAB]))
    }

    func testTwoDevicesConvergeAfterRetriesAndNoStaleResurrection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let macA = try ClipboardCloudJournal(url: root.appendingPathComponent("a.sqlite"))
        let macB = try ClipboardCloudJournal(url: root.appendingPathComponent("b.sqlite"))
        let first = record("first", 1, device: "mac-A")
        XCTAssertTrue(try macA.stageLocal(first))
        XCTAssertEqual(try macB.applyRemote(try macA.pending()), 1)
        XCTAssertEqual(try macB.applyRemote(try macA.pending()), 0)
        let current = try XCTUnwrap(macB.record(id: first.id))
        let delete = current.tombstone(
            revision: try XCTUnwrap(ClipboardCloudRevision.next(
                deviceID: "mac-B", after: current.revision
            ))
        )
        XCTAssertTrue(try macB.stageLocal(delete))
        XCTAssertEqual(try macA.applyRemote(try macB.pending()), 1)
        XCTAssertEqual(try macA.record(id: first.id), delete)
        XCTAssertFalse(try macA.stageLocal(first))
        XCTAssertEqual(try macA.applyRemote([first]), 0)
        XCTAssertEqual(try macA.pendingCount(), 0)
    }

    func testResettingExpiredChangeTokenRetainsPendingAndCachedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("sync.sqlite"))
        let change = record("keep", 4)
        XCTAssertTrue(try journal.stageLocal(change))
        _ = try journal.applyRemote(
            [], zoneID: "private", changeToken: Data([0xA0, 0xB0])
        )
        XCTAssertNotNil(try journal.token(forZone: "private"))
        try journal.resetChangeToken(forZone: "private")
        XCTAssertNil(try journal.token(forZone: "private"))
        XCTAssertEqual(try journal.pendingCount(), 1)
        XCTAssertEqual(try journal.record(id: change.id), change)
    }

    func testBoundedOutboxAndBadTokenNeverMutateState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("sync.sqlite"))
        for index in 0..<5 {
            XCTAssertTrue(try journal.stageLocal(record("c\(index)", Int64(index + 1))))
        }
        XCTAssertEqual(try journal.pending(limit: 2).count, 2)
        XCTAssertEqual(try journal.pending(limit: 2).map(\.revision.counter), [1, 2])
        XCTAssertEqual(try journal.pendingCount(), 5)
        XCTAssertThrowsError(try journal.applyRemote(
            [record("incoming", 9)], zoneID: "private-zone", changeToken: Data()
        ))
        XCTAssertNil(try journal.record(id: "collection:incoming"))
        XCTAssertNil(try journal.token(forZone: "private-zone"))
        XCTAssertEqual(try journal.pendingCount(), 5)
    }
}
