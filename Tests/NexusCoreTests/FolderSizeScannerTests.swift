import Foundation
import XCTest
@testable import NexusCore

final class FolderSizeScannerTests: XCTestCase {
    func testDirectorySizeOnDemandCountsRegularFilesButNotSymlinkTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Python", isDirectory: true)
        let nested = folder.appendingPathComponent("week13", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3072).write(to: folder.appendingPathComponent("archive.zip"))
        try Data(repeating: 2, count: 1200).write(to: nested.appendingPathComponent("notes.txt"))
        let target = root.appendingPathComponent("external-large.bin")
        try Data(repeating: 3, count: 8192).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("shortcut"), withDestinationURL: target
        )
        XCTAssertEqual(try FolderSizeScanner.logicalSize(of: folder), 4272)
        XCTAssertThrowsError(try FolderSizeScanner.logicalSize(of: folder, maxEntries: 1))
        XCTAssertThrowsError(try FolderSizeScanner.logicalSize(of: target))
    }

    func testComputedSizeUpdatesOnlyCorrectTopLevelDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Huge Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("report.pdf")
        try Data(count: 64).write(to: file)
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "copy", urls: [folder, file],
                         sourceApplication: nil, detectionMethod: "clipboard",
                         detectedTimeMS: 500)
        let operation = try XCTUnwrap(store.query(from: 500, to: 501).first)
        try store.markSynced(operationIDs: [operation.id])
        XCTAssertTrue(try store.pendingSync().isEmpty)
        XCTAssertFalse(try store.updateComputedSize(operationID: operation.id,
                                                   position: 0, expectedSource: "/incorrect",
                                                   bytes: 999))
        XCTAssertFalse(try store.updateComputedSize(operationID: operation.id,
                                                   position: 1, expectedSource: file.path,
                                                   bytes: 999))
        XCTAssertTrue(try store.updateComputedSize(operationID: operation.id,
                                                  position: 0, expectedSource: folder.path,
                                                  bytes: 456))
        let reread = try XCTUnwrap(store.query(from: 500, to: 501).first)
        XCTAssertEqual(reread.items[0].size, 456)
        // A revised size must be upserted on the server under the same UUID.
        XCTAssertEqual(try store.pendingSync().map(\.id), [operation.id])
        try store.markSynced(operationIDs: [operation.id])
        XCTAssertFalse(try store.updateComputedSize(operationID: operation.id,
                                                   position: 0, expectedSource: folder.path,
                                                   bytes: 456))
        XCTAssertTrue(try store.pendingSync().isEmpty)
        XCTAssertEqual(reread.items[0].source, folder.path)
        XCTAssertEqual(reread.items[1].size, 64)
        XCTAssertNil(reread.completedTimeMS)
    }
}
