import Foundation
import XCTest
@testable import NexusCore

final class MobileClipboardLocalStoreTests: XCTestCase {
    func testOfflineTextHistorySurvivesReopenAndDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mobile.sqlite")
        var entries: [MobileLocalClipboardEntry] = []
        do {
            let store = try MobileClipboardLocalStore(url: url)
            entries.append(try store.recordText("Python 统计测试", detectedTimeMS: 1))
            entries.append(try store.recordText("Swift 😀", detectedTimeMS: 2))
            XCTAssertEqual(try store.recent().map(\.text),
                           ["Swift 😀", "Python 统计测试"])
        }
        let restored = try MobileClipboardLocalStore(url: url)
        XCTAssertEqual(try restored.recent().count, 2)
        XCTAssertTrue(try restored.delete(id: entries[0].id))
        XCTAssertFalse(try restored.delete(id: entries[0].id))
        XCTAssertEqual(try restored.recent().map(\.id), [entries[1].id])
    }

    func testImportedTextStaysBoundedAndCannotBecomeEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MobileClipboardLocalStore(
            url: root.appendingPathComponent("mobile.sqlite")
        )
        XCTAssertThrowsError(try store.recordText("", detectedTimeMS: 1))
        XCTAssertThrowsError(try store.recordText(
            String(repeating: "x", count: 64 * 1024 + 1),
            detectedTimeMS: 1
        ))
        XCTAssertThrowsError(try store.recordText("hello", detectedTimeMS: -1))
        let maximum = String(repeating: "x", count: 64 * 1024)
        XCTAssertNotNil(try store.recordText(maximum, detectedTimeMS: 2).id)
        XCTAssertEqual(try store.recent().first?.text.utf8.count, 64 * 1024)
    }

    func testHistoryPrunesOldestAfterFiveHundredRecordsWithoutCloud() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MobileClipboardLocalStore(
            url: root.appendingPathComponent("mobile.sqlite")
        )
        for number in 0..<507 {
            try store.recordText("entry \(number)",
                                 detectedTimeMS: Int64(number + 1))
        }
        let items = try store.recent(limit: 600)
        XCTAssertEqual(items.count, MobileClipboardLocalStore.maximumEntries)
        XCTAssertEqual(items.first?.text, "entry 506")
        XCTAssertEqual(items.last?.text, "entry 7")
    }
}
