import Foundation
import XCTest
@testable import NexusCore

final class ClipboardFolderTransportTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-folder-tests-\(UUID().uuidString)", isDirectory: true)
        let selected = root.appendingPathComponent(
            ClipboardFolderTransport.folderName, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selected, withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return selected
    }

    private func record(counter: Int64 = 1,
                        id: String = "collection:example") -> ClipboardCloudRecord {
        ClipboardCloudRecord(
            id: id, kind: .collection,
            revision: ClipboardCloudRevision(counter: counter, deviceID: "Test-Mac"),
            payload: .collection(ClipboardCloudCollection(name: "Example"))
        )
    }

    func testRequiresExplicitFolderInitialization() async throws {
        let folder = try temporaryFolder()
        let transport = ClipboardFolderTransport(folderURL: folder)
        do {
            _ = try await transport.fetch(after: nil)
            XCTFail("An unprepared folder must not be read")
        } catch ClipboardFolderTransport.FolderError.notPrepared {
            // expected
        }
        try await transport.prepareFolderIfRequested()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("changes").path
        ))
        let page = try await transport.fetch(after: nil)
        XCTAssertTrue(page.changes.isEmpty)
    }

    func testMutationUploadAndDownloadAreIdempotent() async throws {
        let folder = try temporaryFolder()
        let sender = ClipboardFolderTransport(folderURL: folder)
        let receiver = ClipboardFolderTransport(folderURL: folder)
        try await sender.prepareFolderIfRequested()
        let entry = record()
        let first = try await sender.upload([entry], permissionCheck: { _ in true })
        let second = try await sender.upload([entry], permissionCheck: { _ in true })
        XCTAssertEqual(first, second)
        let page = try await receiver.fetch(after: nil)
        XCTAssertEqual(page.changes, [entry])
        XCTAssertFalse(page.moreComing)
    }

    func testDeniedConsentDoesNotWriteAnyDocument() async throws {
        let folder = try temporaryFolder()
        let transport = ClipboardFolderTransport(folderURL: folder)
        try await transport.prepareFolderIfRequested()
        let result = try await transport.upload([record()], permissionCheck: { _ in false })
        XCTAssertTrue(result.isEmpty)
        let page = try await transport.fetch(after: nil)
        XCTAssertTrue(page.changes.isEmpty)
    }

    func testDeletionIsRestrictedToOwnedSyncFiles() async throws {
        let folder = try temporaryFolder()
        let transport = ClipboardFolderTransport(folderURL: folder)
        try await transport.prepareFolderIfRequested()
        _ = try await transport.upload([record()], permissionCheck: { _ in true })
        let unrelated = folder.appendingPathComponent("do-not-delete.txt")
        try Data("keep".utf8).write(to: unrelated)
        try await transport.deletePrivateNexusZone()
        let page = try await transport.fetch(after: nil)
        XCTAssertTrue(page.changes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
