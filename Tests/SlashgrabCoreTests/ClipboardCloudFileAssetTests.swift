import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudFileAssetTests: XCTestCase {
    func testSingleLocalFileRequiresIndependentConsentAndNeverUploadsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("期中报告.txt")
        let bytes = Data("统计学作业与注释".utf8)
        try bytes.write(to: fileURL)
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        let journal = try ClipboardCloudJournal(url: directory.appendingPathComponent("journal.sqlite"))
        try store.record(type: "copy", urls: [fileURL],
                         sourceApplication: "com.example.files",
                         detectionMethod: "clipboard", detectedTimeMS: 190)
        let noFileConsent = ClipboardCloudConsent(enabled: true, includeNames: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "MacA", consent: noFileConsent
        )
        let original = try XCTUnwrap(journal.pending().first)
        guard case .operation(let initial)? = original.payload else {
            return XCTFail("missing initial operation")
        }
        XCTAssertNil(initial.file)

        let consent = ClipboardCloudConsent(enabled: true, includeFiles: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: store, in: journal, deviceID: "MacA", consent: consent
        )
        let record = try XCTUnwrap(journal.pending().first)
        guard case .operation(let operation)? = record.payload else {
            return XCTFail("missing single-file operation")
        }
        let reference = try XCTUnwrap(operation.file)
        XCTAssertEqual(reference.fileName, "期中报告.txt")
        XCTAssertEqual(reference.byteCount, bytes.count)
        XCTAssertNil(operation.items.first?.path, "Sender absolute path must remain private")
        XCTAssertFalse(noFileConsent.permits(record))
        XCTAssertTrue(consent.permits(record))

        let sourceID = String(record.id.dropFirst("operation:".count))
        let asset = try XCTUnwrap(store.cloudFileAsset(operationID: sourceID))
        XCTAssertTrue(asset.matches(reference))

        let remote = try ClipboardCloudJournal(url: directory.appendingPathComponent("receiving.sqlite"))
        let token = Data([0x1,0x2])
        let corrupt = try XCTUnwrap(ClipboardCloudFileAsset(
            bytes: Data([0x40]), fileName: "期中报告.txt"
        ))
        XCTAssertThrowsError(try remote.applyRemote(
            [record], zoneID: "NexusClipboard", changeToken: token,
            fileAssets: [record.id: corrupt]
        ))
        XCTAssertNil(try remote.token(forZone: "NexusClipboard"))

        XCTAssertEqual(try remote.applyRemote(
            [record], zoneID: "NexusClipboard", changeToken: token,
            fileAssets: [record.id: asset]
        ), 1)
        XCTAssertEqual(try remote.cachedFile(recordID: record.id)?.bytes, bytes)
        XCTAssertEqual(try remote.token(forZone: "NexusClipboard"), token)
        let deletion = record.tombstone(
            revision: ClipboardCloudRevision(counter: 3, deviceID: "MacB")
        )
        XCTAssertEqual(try remote.applyRemote(
            [deletion], zoneID: "NexusClipboard",
            changeToken: Data([0x3])
        ), 1)
        XCTAssertNil(try remote.cachedFile(recordID: record.id))
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    func testRejectsPathTraversalSymlinksOversizeAndInvalidDigests() throws {
        let bytes = Data("safe".utf8)
        for invalid in ["", ".", "..", "../test.txt", "a/b.txt", "a\\b.txt",
                        "bad\nname.txt", String(repeating: "n", count: 201)] {
            XCTAssertNil(ClipboardCloudFileReference(
                bytes: bytes, fileName: invalid
            ), invalid)
        }
        XCTAssertNil(ClipboardCloudFileAsset(
            bytes: Data(), fileName: "empty.txt"
        ))
        XCTAssertNil(ClipboardCloudFileAsset(
            bytes: Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1),
            fileName: "large.txt"
        ))
        let asset = try XCTUnwrap(ClipboardCloudFileAsset(
            bytes: bytes, fileName: "safe.txt"
        ))
        XCTAssertFalse(asset.reference.verifies(Data("wrong".utf8)))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("safe.txt")
        try bytes.write(to: original)
        let link = folder.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: link.path,
            maximumBytes: Int64(ClipboardCloudFileReference.maximumBytes)))
        let store = try OperationStore(url: folder.appendingPathComponent("store.sqlite"))
        try store.record(type: "copy", urls: [link], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 3)
        let id = try XCTUnwrap(store.query(from: 0, to: 10).first?.id)
        XCTAssertNil(try store.cloudFileAsset(operationID: id))
    }

    func testLocalCloudPurgeRemovesOnlyDownloadedFileCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("File payload".utf8)
        let file = try XCTUnwrap(ClipboardCloudFileAsset(
            bytes: bytes, fileName: "example.txt"
        ))
        let change = ClipboardCloudRecord(
            id: ClipboardCloudRecord.operationID(UUID().uuidString),
            kind: .operation,
            revision: ClipboardCloudRevision(counter: 1, deviceID: "MacA"),
            payload: .operation(ClipboardCloudOperation(
                type: "copy", detectedTimeMS: 1,
                sourceApplication: nil,
                items: [ClipboardCloudItem(kind: "file", size: Int64(bytes.count),
                                           name: nil, path: nil)],
                text: nil, image: nil, file: file.reference
            ))
        )
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("cloud.sqlite"))
        try journal.applyRemote([change], fileAssets: [change.id: file])
        XCTAssertEqual(try journal.cachedFile(recordID: change.id)?.bytes, bytes)
        try journal.discardAllLocalCloudData()
        XCTAssertNil(try journal.cachedFile(recordID: change.id))
    }
}
