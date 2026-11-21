import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardTextDuplicatePolicyTests: XCTestCase {
    private func makeStore() throws -> (OperationStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (try OperationStore(url: root.appendingPathComponent("history.sqlite")), root)
    }

    func testKeepEveryCopyIsLosslessDefaultAndOptInRefreshPreservesID() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.recordTextCopy("你好 Swift", detectedTimeMS: 100)
        let second = try store.recordTextCopy("你好 Swift", detectedTimeMS: 101)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.query(from: 0, to: 200).count, 2)

        let refreshed = try store.recordTextCopy(
            "你好 Swift", detectedTimeMS: 150,
            observedForegroundBundleID: "com.apple.Safari",
            policy: .refreshLatest
        )
        XCTAssertEqual(refreshed, second)
        XCTAssertEqual(try store.query(from: 0, to: 200).count, 2)
        let newest = try XCTUnwrap(store.query(from: 0, to: 200).first)
        XCTAssertEqual(newest.id, second)
        XCTAssertEqual(newest.detectedTimeMS, 150)
        XCTAssertEqual(newest.sourceApplication, "com.apple.Safari")
    }

    func testFileOrImageAndOlderThanTenMinutesBreakSequence() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.recordTextCopy(
            "repeat", detectedTimeMS: 1, policy: .refreshLatest
        )
        try store.record(type: "image_copy", urls: [],
                         sourceApplication: nil,
                         detectionMethod: "clipboard",
                         detectedTimeMS: 2)
        let second = try store.recordTextCopy(
            "repeat", detectedTimeMS: 3, policy: .refreshLatest
        )
        XCTAssertNotEqual(first, second)
        let muchLater = try store.recordTextCopy(
            "repeat", detectedTimeMS: 600_004, policy: .refreshLatest
        )
        XCTAssertNotEqual(second, muchLater)
        XCTAssertEqual(try store.query(from: 0, to: 600_010).count, 4)
    }

    func testRichTextDoesNotGetOverwrittenByPlainTextDedup() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try XCTUnwrap(ClipboardRichTextPreview(
            text: "Bold",
            runs: [ClipboardRichTextRun(
                locationUTF16: 0, lengthUTF16: 4,
                bold: true, italic: false, underline: false
            )]
        ))
        let richID = try store.recordRichText(preview, detectedTimeMS: 10)
        let plainID = try store.recordTextCopy(
            "Bold", detectedTimeMS: 11, policy: .refreshLatest
        )
        XCTAssertNotEqual(richID, plainID)
        XCTAssertEqual(try store.richTextPreview(operationID: richID), preview)
    }

    func testOptInRefreshRequeuesPreviouslyUploadedMetadata() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try store.recordTextCopy(
            "sample", detectedTimeMS: 40, policy: .refreshLatest
        )
        try store.markSynced(operationIDs: [id])
        XCTAssertFalse(try store.pendingSync().contains { $0.id == id })
        let same = try store.recordTextCopy(
            "sample", detectedTimeMS: 41, policy: .refreshLatest
        )
        XCTAssertEqual(same, id)
        XCTAssertTrue(try store.pendingSync().contains { $0.id == id })
    }
}
