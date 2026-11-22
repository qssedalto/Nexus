import Foundation
import XCTest
@testable import NexusCore

private actor MockZoneDeletion: ClipboardCloudPrivateZoneDeletion {
    enum Failure: Error { case network }
    private(set) var calls = 0
    var shouldFail = false

    func deletePrivateNexusZone() async throws {
        calls += 1
        if shouldFail { throw Failure.network }
    }

    func setFailure(_ value: Bool) { shouldFail = value }
    func callCount() -> Int { calls }
}

final class ClipboardCloudPurgeTests: XCTestCase {
    private func makeJournal() throws -> (ClipboardCloudJournal, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let journal = try ClipboardCloudJournal(
            url: root.appendingPathComponent("cloud.sqlite")
        )
        let record = ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(UUID().uuidString),
            kind: .collection,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "Mac-A"),
            payload: .collection(ClipboardCloudCollection(name: "私密收藏"))
        )
        try journal.stageLocal(record)
        _ = try journal.applyRemote(
            [], zoneID: "NexusClipboard", changeToken: Data([0xAA, 0xBB])
        )
        return (journal, root)
    }

    func testConfirmationIsMandatoryAndMakesNoNetworkCalls() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = MockZoneDeletion()
        let purge = ClipboardCloudPurgeCoordinator(
            transport: remote, journal: journal
        )
        do {
            try await purge.purgeCloudZoneAndLocalCache()
            XCTFail("Must require explicit user confirmation")
        } catch ClipboardCloudPurgeError.explicitConfirmationRequired {
            let calls = await remote.callCount()
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try journal.pendingCount(), 1)
            XCTAssertNotNil(try journal.token(forZone: "NexusClipboard"))
        }
        for invalid in ["delete", " DELETE", "DELETE ", "CONFIRM", ""] {
            do {
                try await purge.purgeCloudZoneAndLocalCache(confirmation: invalid)
                XCTFail("Invalid text must not delete the private zone")
            } catch ClipboardCloudPurgeError.explicitConfirmationRequired {
                let calls = await remote.callCount()
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testFailedRemotePurgeDoesNotClearLocalRecoveryData() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = MockZoneDeletion()
        await remote.setFailure(true)
        let purge = ClipboardCloudPurgeCoordinator(
            transport: remote, journal: journal
        )
        do {
            try await purge.purgeCloudZoneAndLocalCache(confirmation: "DELETE")
            XCTFail("Expected a network failure")
        } catch MockZoneDeletion.Failure.network {
            XCTAssertEqual(try journal.pendingCount(), 1)
            XCTAssertEqual(try journal.cachedRecords().count, 1)
            XCTAssertEqual(try journal.token(forZone: "NexusClipboard"),
                           Data([0xAA, 0xBB]))
        }
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testMirrorCleanupFailureAfterRemoteDeletionKeepsLocalRecovery() async throws {
        enum MirrorFailure: Error { case storage }
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = MockZoneDeletion()
        let purge = ClipboardCloudPurgeCoordinator(
            transport: remote, journal: journal
        )
        do {
            try await purge.purgeCloudZoneAndLocalCache(
                confirmation: "DELETE",
                afterRemoteDeletion: { throw MirrorFailure.storage }
            )
            XCTFail("Expected mirror cleanup failure")
        } catch MirrorFailure.storage {
            XCTAssertEqual(try journal.pendingCount(), 1)
            XCTAssertNotNil(try journal.token(forZone: "NexusClipboard"))
            XCTAssertEqual(try journal.cachedRecords().count, 1)
        }
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 1)
        // Repeat after fixing local storage; a missing server zone is
        // considered successful by the production transport.
        try await purge.purgeCloudZoneAndLocalCache(
            confirmation: "DELETE",
            afterRemoteDeletion: {}
        )
        XCTAssertEqual(try journal.pendingCount(), 0)
        XCTAssertNil(try journal.token(forZone: "NexusClipboard"))
    }

    func testSuccessfulPurgeClearsOutboxCacheAndTokenAcrossRestart() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = MockZoneDeletion()
        let purge = ClipboardCloudPurgeCoordinator(
            transport: remote, journal: journal
        )
        try await purge.purgeCloudZoneAndLocalCache(confirmation: "DELETE")
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try journal.pendingCount(), 0)
        XCTAssertTrue(try journal.cachedRecords().isEmpty)
        XCTAssertNil(try journal.token(forZone: "NexusClipboard"))
        let reopened = try ClipboardCloudJournal(
            url: root.appendingPathComponent("cloud.sqlite")
        )
        XCTAssertEqual(try reopened.pendingCount(), 0)
        XCTAssertNil(try reopened.token(forZone: "NexusClipboard"))
    }

    func testClearingLocalMirrorRowsNeverRemovesOriginalHistoryOrCollections() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("ops.sqlite"))
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 1,
                         clipboardText: "Keep local history")
        let original = try XCTUnwrap(store.query(from: 0, to: 5).first)
        let userCollection = try store.createCollection(named: "Local collection")
        let remote = ClipboardCloudRecord(
            id: ClipboardCloudRecord.operationID(UUID().uuidString),
            kind: .operation,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "Mac-B"),
            payload: .operation(ClipboardCloudOperation(
                record: original,
                consent: ClipboardCloudConsent(enabled: true, includeText: true)
            )!)
        )
        let cloudCollection = ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(UUID().uuidString),
            kind: .collection,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "Mac-B"),
            payload: .collection(ClipboardCloudCollection(name: "Cloud collection"))
        )
        let consent = ClipboardCloudConsent(
            enabled: true, includeText: true, includeNames: true
        )
        XCTAssertEqual(try store.importCloudHistory([remote], consent: consent), 1)
        XCTAssertEqual(try store.importCloudCollections(
            [cloudCollection], consent: consent
        ), 1)
        XCTAssertEqual(try store.discardImportedCloudMirrors(), 2)
        XCTAssertEqual(try store.discardImportedCloudMirrors(), 0)
        XCTAssertEqual(try store.query(from: 0, to: 5).count, 1)
        XCTAssertEqual(try store.query(from: 0, to: 5).first?.id, original.id)
        let remaining = try store.listCollections()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, userCollection.id)
    }
}
