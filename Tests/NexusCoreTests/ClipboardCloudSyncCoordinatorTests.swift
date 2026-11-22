import Foundation
import XCTest
@testable import NexusCore

private actor MockClipboardCloudTransport: ClipboardCloudTransport {
    enum Failure: Error { case upload, fetch }

    private(set) var uploadedBatches: [[ClipboardCloudRecord]] = []
    private(set) var fetchTokens: [Data?] = []
    var acknowledgements: [ClipboardCloudUploadAck]?
    var download = ClipboardCloudDownloadPage(changes: [], token: nil)
    var failUpload = false
    var failFetch = false

    func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck] {
        if failUpload { throw Failure.upload }
        for record in records {
            guard await permissionCheck(record) else {
                throw ClipboardCloudSyncError.consentRequired
            }
        }
        uploadedBatches.append(records)
        return acknowledgements ?? records.map {
            ClipboardCloudUploadAck(id: $0.id, mutationID: $0.mutationID)
        }
    }

    func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage {
        if failFetch { throw Failure.fetch }
        fetchTokens.append(token)
        return download
    }

    func setAcks(_ result: [ClipboardCloudUploadAck]?) { acknowledgements = result }
    func setDownload(_ page: ClipboardCloudDownloadPage) { download = page }
    func setFailure(upload: Bool = false, fetch: Bool = false) {
        failUpload = upload
        failFetch = fetch
    }
    func calls() -> (uploads: Int, fetches: Int) {
        (uploadedBatches.count, fetchTokens.count)
    }
}

final class ClipboardCloudSyncCoordinatorTests: XCTestCase {
    private func setup() throws -> ClipboardCloudJournal {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try ClipboardCloudJournal(url: root.appendingPathComponent("cloud.sqlite"))
    }

    private func membership(_ id: String, counter: Int64 = 1) -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.membershipID(collectionID: "c", operationID: id),
            kind: .membership,
            revision: ClipboardCloudRevision(counter: counter, deviceID: "Mac-A"),
            payload: .membership(ClipboardCloudMembership(
                collectionID: "c", operationID: id, sortPosition: 1
            ))
        )
    }

    private func namedCollection() -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID("c"), kind: .collection,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "Mac-A"),
            payload: .collection(ClipboardCloudCollection(name: "敏感收藏"))
        )
    }

    func testDisabledConsentMakesNoProviderCallsOrDiskChanges() async throws {
        let journal = try setup()
        let record = membership("x")
        try journal.stageLocal(record)
        let provider = MockClipboardCloudTransport()
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        let report = try await coordinator.syncOnce(consent: .init())
        XCTAssertEqual(report, .disabled)
        let calls = await provider.calls()
        XCTAssertEqual(calls.uploads, 0)
        XCTAssertEqual(calls.fetches, 0)
        XCTAssertEqual(try journal.pendingCount(), 1)
    }

    func testPartialAcknowledgementsKeepUnconfirmedMutationsForRetry() async throws {
        let journal = try setup()
        let a = membership("a")
        let b = membership("b")
        try journal.stageLocal(a)
        try journal.stageLocal(b)
        let provider = MockClipboardCloudTransport()
        await provider.setAcks([
            ClipboardCloudUploadAck(id: a.id, mutationID: a.mutationID)
        ])
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        let consent = ClipboardCloudConsent(enabled: true)
        let first = try await coordinator.syncOnce(consent: consent)
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(first.pending, 1)
        XCTAssertEqual(try journal.pending().map(\.id), [b.id])
        await provider.setAcks(nil)
        let second = try await coordinator.syncOnce(consent: consent)
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(second.pending, 0)
    }

    func testUnexpectedAckCannotDiscardUnrelatedLocalWork() async throws {
        let journal = try setup()
        try journal.stageLocal(membership("x"))
        let provider = MockClipboardCloudTransport()
        await provider.setAcks([
            ClipboardCloudUploadAck(id: "membership:forged",
                                    mutationID: UUID().uuidString)
        ])
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consent: .init(enabled: true))
            XCTFail("Expected a mismatched acknowledgement")
        } catch ClipboardCloudSyncError.unexpectedAcknowledgement {
            XCTAssertEqual(try journal.pendingCount(), 1)
            let calls = await provider.calls()
            XCTAssertEqual(calls.fetches, 1,
                           "Remote reconciliation is intentionally fetched before upload")
        }
    }

    func testRevokingNameConsentPreventsQueuedNameUpload() async throws {
        let journal = try setup()
        try journal.stageLocal(namedCollection())
        let provider = MockClipboardCloudTransport()
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consent: .init(enabled: true))
            XCTFail("Collection name must require explicit consent")
        } catch ClipboardCloudSyncError.unauthorizedContents {
            XCTAssertEqual(try journal.pendingCount(), 1)
            let calls = await provider.calls()
            XCTAssertEqual(calls.uploads, 0)
        }
        let allowed = try await coordinator.syncOnce(
            consent: .init(enabled: true, includeNames: true)
        )
        XCTAssertEqual(allowed.uploaded, 1)
    }

    func testIncomingPageAndOpaqueTokenAreCommittedTogether() async throws {
        let journal = try setup()
        let provider = MockClipboardCloudTransport()
        let remote = membership("remote", counter: 7)
        await provider.setDownload(.init(changes: [remote], token: Data([0x45, 0x46]),
                                         moreComing: true))
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        let first = try await coordinator.syncOnce(consent: .init(enabled: true))
        XCTAssertEqual(first.downloaded, 1)
        XCTAssertTrue(first.moreComing)
        XCTAssertEqual(try journal.record(id: remote.id), remote)
        XCTAssertEqual(try journal.token(forZone: "private"), Data([0x45, 0x46]))
        let second = try await coordinator.syncOnce(consent: .init(enabled: true))
        XCTAssertEqual(second.downloaded, 0)
        let calls = await provider.calls()
        XCTAssertEqual(calls.fetches, 2)
    }

    func testServerWinnerIsMergedBeforeLocalUploadToAvoidConflictLoop() async throws {
        let journal = try setup()
        let local = membership("conflicted", counter: 2)
        let remote = ClipboardCloudRecord(
            id: local.id, kind: .membership,
            revision: ClipboardCloudRevision(counter: 8, deviceID: "Mac-B"),
            payload: .membership(ClipboardCloudMembership(
                collectionID: "c", operationID: "conflicted", sortPosition: 30
            ))
        )
        try journal.stageLocal(local)
        let provider = MockClipboardCloudTransport()
        await provider.setDownload(.init(changes: [remote], token: Data([0x1])))
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        let report = try await coordinator.syncOnce(consent: .init(enabled: true))
        XCTAssertEqual(report.downloaded, 1)
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(report.pending, 0)
        XCTAssertEqual(try journal.record(id: local.id), remote)
        let calls = await provider.calls()
        XCTAssertEqual(calls.uploads, 0)
        XCTAssertEqual(calls.fetches, 1)
    }

    func testMultipleServerPagesDrainBeforeAnyLocalUpload() async throws {
        let journal = try setup()
        try journal.stageLocal(membership("local"))
        let provider = MockClipboardCloudTransport()
        await provider.setDownload(.init(
            changes: [membership("remote")],
            token: Data([0x2]), moreComing: true
        ))
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        let first = try await coordinator.syncOnce(consent: .init(enabled: true))
        XCTAssertEqual(first.uploaded, 0)
        XCTAssertTrue(first.moreComing)
        XCTAssertEqual(try journal.pendingCount(), 1)
        await provider.setDownload(.init(changes: [], token: Data([0x3])))
        let second = try await coordinator.syncOnce(consent: .init(enabled: true))
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertFalse(second.moreComing)
        let calls = await provider.calls()
        XCTAssertEqual(calls.uploads, 1)
    }

    func testDownloadFailureLeavesCheckpointUnchangedAndLocalAckSafe() async throws {
        let journal = try setup()
        try journal.stageLocal(membership("local"))
        let provider = MockClipboardCloudTransport()
        await provider.setFailure(fetch: true)
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: provider, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consent: .init(enabled: true))
            XCTFail("Expected provider fetch failure")
        } catch MockClipboardCloudTransport.Failure.fetch {
            XCTAssertEqual(try journal.pendingCount(), 1,
                           "Fetch failure must not send or acknowledge local changes")
            XCTAssertNil(try journal.token(forZone: "private"))
        }
    }
}


/// Real local file I/O tests: the free transport is never permitted to
/// write readable clipboard text to the user's iCloud Drive folder.
final class ClipboardFolderTransportTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(ClipboardFolderTransport.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func collection(_ name: String = "私人收藏集合") -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID("sample"),
            kind: .collection,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "test-mac"),
            payload: .collection(ClipboardCloudCollection(name: name))
        )
    }

    func testEncryptedFolderTransportRoundTripAndRetry() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let transport = try ClipboardFolderTransport(folderURL: folder,
            keyData: Data(repeating: 0x42, count: 32))
        try await transport.prepareFolderIfRequested()
        let record = collection()
        let acknowledgements = try await transport.upload([record], permissionCheck: { _ in true })
        XCTAssertEqual(acknowledgements.count, 1)
        let root = folder.appendingPathComponent("encrypted-changes", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let raw = try Data(contentsOf: try XCTUnwrap(files.first))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("私人收藏集合"),
                       "iCloud Drive must never contain plaintext collection names")
        let page = try await transport.fetch(after: nil)
        XCTAssertEqual(page.changes, [record])
        XCTAssertEqual(page.token, Data("0".utf8))
        let retried = try await transport.upload([record], permissionCheck: { _ in true })
        XCTAssertEqual(retried.count, 1, "An immutable retry must not create a duplicate")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).count, 1)
    }

    func testIncorrectPairingKeyCannotReadRecords() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let original = try ClipboardFolderTransport(folderURL: folder,
            keyData: Data(repeating: 0x11, count: 32))
        try await original.prepareFolderIfRequested()
        _ = try await original.upload([collection()], permissionCheck: { _ in true })
        let wrong = try ClipboardFolderTransport(folderURL: folder,
            keyData: Data(repeating: 0x22, count: 32))
        do {
            _ = try await wrong.fetch(after: nil)
            XCTFail("Wrong secret should never decrypt an encrypted change")
        } catch {
            // Authentication failure is required. No partial import.
        }
    }

    func testRevokedConsentPreventsFileCreation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let transport = try ClipboardFolderTransport(folderURL: folder,
            keyData: Data(repeating: 0x66, count: 32))
        try await transport.prepareFolderIfRequested()
        let acknowledgements = try await transport.upload([collection()],
            permissionCheck: { _ in false })
        XCTAssertTrue(acknowledgements.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: folder.appendingPathComponent("encrypted-changes"),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }
}
