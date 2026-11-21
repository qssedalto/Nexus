import XCTest
@testable import NexusCore

final class ClipboardCloudUploadDecisionTests: XCTestCase {
    private func version(_ counter: Int64, _ device: String = "mac-A",
                         name: String = "Collection") -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID("c"), kind: .collection,
            revision: ClipboardCloudRevision(counter: counter, deviceID: device),
            payload: .collection(ClipboardCloudCollection(name: name))
        )
    }

    func testExactRetryCanBeAcknowledged() throws {
        let sent = version(3)
        XCTAssertEqual(
            try ClipboardCloudUploadDecision.decide(local: sent, server: sent),
            .acknowledgeExactRetry
        )
    }

    func testLocalNewerMutationMustBeWritten() throws {
        let server = version(2, "mac-B")
        let local = version(4, "mac-A")
        XCTAssertEqual(
            try ClipboardCloudUploadDecision.decide(local: local, server: server),
            .uploadNewVersion
        )
    }

    func testRemoteNewerOrTombstoneMustNotAcknowledgeOldLocal() throws {
        let local = version(4, "mac-A")
        let newerRemote = version(5, "mac-B")
        XCTAssertEqual(
            try ClipboardCloudUploadDecision.decide(local: local, server: newerRemote),
            .requiresRemoteReconciliation
        )
        let deletion = local.tombstone(
            revision: ClipboardCloudRevision(counter: 4, deviceID: "mac-B")
        )
        XCTAssertEqual(
            try ClipboardCloudUploadDecision.decide(local: local, server: deletion),
            .requiresRemoteReconciliation
        )
    }

    func testSameClockDifferentMutationIsNotAnExactRetry() throws {
        let local = version(7, "mac-A", name: "A")
        let remote = version(7, "mac-A", name: "B")
        let decision = try ClipboardCloudUploadDecision.decide(
            local: local, server: remote
        )
        XCTAssertNotEqual(decision, .acknowledgeExactRetry)
    }
}
