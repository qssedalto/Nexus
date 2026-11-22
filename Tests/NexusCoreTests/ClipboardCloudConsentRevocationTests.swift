import Foundation
import XCTest
@testable import NexusCore

private actor MutableCloudConsent {
    private var value: ClipboardCloudConsent

    init(_ value: ClipboardCloudConsent) { self.value = value }

    func current() -> ClipboardCloudConsent { value }
    func change(to next: ClipboardCloudConsent) { value = next }
}

private actor ConsentRevokingTransport: ClipboardCloudTransport {
    private let consent: MutableCloudConsent
    private let revisedConsent: ClipboardCloudConsent
    private let incoming: ClipboardCloudDownloadPage
    private(set) var uploads = 0
    private(set) var downloads = 0

    init(consent: MutableCloudConsent, next: ClipboardCloudConsent,
         page: ClipboardCloudDownloadPage = .init(changes: [], token: nil)) {
        self.consent = consent
        revisedConsent = next
        incoming = page
    }

    func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage {
        downloads += 1
        await consent.change(to: revisedConsent)
        return incoming
    }

    func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck] {
        var acknowledgements: [ClipboardCloudUploadAck] = []
        for record in records {
            guard await permissionCheck(record) else {
                throw ClipboardCloudSyncError.consentRequired
            }
            uploads += 1
            acknowledgements.append(ClipboardCloudUploadAck(
                id: record.id, mutationID: record.mutationID
            ))
        }
        return acknowledgements
    }

    func counts() -> (Int, Int) { (downloads, uploads) }
}

/// Simulates a user revoking collection-name permission after the first
/// CKRecord was sent, while the remainder of the batch is still queued.
private actor RevokingMidBatchTransport: ClipboardCloudTransport {
    let state: MutableCloudConsent
    private(set) var sentRecordIDs: [String] = []

    init(state: MutableCloudConsent) { self.state = state }

    func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage {
        ClipboardCloudDownloadPage(changes: [], token: nil)
    }

    func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck] {
        var accepted: [ClipboardCloudUploadAck] = []
        for record in records {
            guard await permissionCheck(record) else {
                throw ClipboardCloudSyncError.consentRequired
            }
            sentRecordIDs.append(record.id)
            accepted.append(ClipboardCloudUploadAck(
                id: record.id, mutationID: record.mutationID
            ))
            if sentRecordIDs.count == 1 {
                await state.change(to: .init(enabled: true, includeNames: false))
            }
        }
        return accepted
    }

    func sent() -> [String] { sentRecordIDs }
}

final class ClipboardCloudConsentRevocationTests: XCTestCase {
    private func makeJournal() throws -> (ClipboardCloudJournal, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (
            try ClipboardCloudJournal(url: root.appendingPathComponent("sync.sqlite")),
            root
        )
    }

    private func namedCollection() -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(UUID().uuidString),
            kind: .collection,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "Mac-A"),
            payload: .collection(ClipboardCloudCollection(name: "个人资料"))
        )
    }

    func testDisablingSyncDuringFetchStopsUploadAndRemoteImport() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = namedCollection()
        let remote = namedCollection()
        try journal.stageLocal(local)
        let state = MutableCloudConsent(.init(enabled: true, includeNames: true))
        let transport = ConsentRevokingTransport(
            consent: state, next: .init(),
            page: .init(changes: [remote], token: Data([1, 2]))
        )
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: transport, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consentProvider: {
                await state.current()
            })
            XCTFail("The user revoked cloud synchronization mid-fetch")
        } catch ClipboardCloudSyncError.consentRequired {
            XCTAssertEqual(try journal.pendingCount(), 1)
            XCTAssertNil(try journal.record(id: remote.id))
            XCTAssertNil(try journal.token(forZone: "private"))
            let counts = await transport.counts()
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, 0)
        }
    }

    func testRevokingCollectionNamesDuringFetchCannotUploadQueuedName() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        try journal.stageLocal(namedCollection())
        let state = MutableCloudConsent(.init(enabled: true, includeNames: true))
        let transport = ConsentRevokingTransport(
            consent: state,
            next: .init(enabled: true, includeNames: false)
        )
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: transport, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consentProvider: {
                await state.current()
            })
            XCTFail("A queued collection name must not upload after revocation")
        } catch ClipboardCloudSyncError.unauthorizedContents {
            XCTAssertEqual(try journal.pendingCount(), 1)
            let counts = await transport.counts()
            XCTAssertEqual(counts.1, 0)
        }
    }

    func testRevokedNamesCannotBeImportedWithAnAdvancedCheckpoint() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = namedCollection()
        let state = MutableCloudConsent(.init(enabled: true, includeNames: true))
        let transport = ConsentRevokingTransport(
            consent: state, next: .init(enabled: true),
            page: .init(changes: [incoming], token: Data([0xAA]))
        )
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: transport, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consentProvider: {
                await state.current()
            })
            XCTFail("No named collections may be imported after names are revoked")
        } catch ClipboardCloudSyncError.unauthorizedContents {
            XCTAssertNil(try journal.record(id: incoming.id))
            XCTAssertNil(try journal.token(forZone: "private"))
        }
    }
    func testPerRecordAuthorizationStopsSubsequentWritesDuringAnUploadBatch() async throws {
        let (journal, root) = try makeJournal()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = namedCollection()
        let b = namedCollection()
        try journal.stageLocal(a)
        try journal.stageLocal(b)
        let state = MutableCloudConsent(.init(enabled: true, includeNames: true))
        let transport = RevokingMidBatchTransport(state: state)
        let coordinator = try ClipboardCloudSyncCoordinator(
            journal: journal, transport: transport, zoneID: "private"
        )
        do {
            _ = try await coordinator.syncOnce(consentProvider: {
                await state.current()
            })
            XCTFail("Second CKRecord must be blocked after the user revokes names")
        } catch ClipboardCloudSyncError.consentRequired {
            let transmitted = await transport.sent()
            XCTAssertEqual(transmitted.count, 1,
                           "Only the first already-authorized record may have been sent")
            XCTAssertEqual(try journal.pendingCount(), 2,
                           "Unknown partial acknowledgements must remain retryable")
        }
    }

}
