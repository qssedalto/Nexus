import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardHistorySearchTests: XCTestCase {
    func testFindsOldChineseTextBeyondRecentShelfWithoutLoadingAllRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))

        for index in 0..<251 {
            try store.record(
                type: "text_copy", urls: [],
                sourceApplication: index == 0 ? "com.example.Editor" : nil,
                detectionMethod: "clipboard",
                detectedTimeMS: Int64(1_000 + index),
                clipboardText: index == 0 ? "古老的剪贴板 history_%" : "recent text \(index)"
            )
        }
        XCTAssertEqual(
            try store.searchClipboard(query: "古老").map(\.clipboardText),
            ["古老的剪贴板 history_%"]
        )
        XCTAssertEqual(try store.searchClipboard(query: "_%").count, 1,
                       "Literal wildcard characters must not match unrelated text")
        XCTAssertEqual(
            try store.searchClipboard(query: "history", sourceApplication: "editor").count,
            1
        )
        XCTAssertTrue(try store.searchClipboard(query: "history",
                                                 sourceApplication: "Browser").isEmpty)
        XCTAssertTrue(try store.searchClipboard(query: "古老",
                                                 from: 1_001, to: 2_000).isEmpty)
        XCTAssertEqual(try store.searchClipboard(query: "", kind: .text, limit: 5).count, 5)
        XCTAssertEqual(try store.searchClipboard(query: "recent", kind: .text, limit: 1)
            .first?.clipboardText, "recent text 250")
    }

    func testStablePagedSearchReturnsOlderMatchesWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        for index in 0..<451 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard",
                             detectedTimeMS: Int64(index + 1),
                             clipboardText: "PageTest \(index)")
        }
        let first = try store.searchClipboard(query: "PageTest", limit: 200, offset: 0)
        let second = try store.searchClipboard(query: "PageTest", limit: 200, offset: 200)
        let third = try store.searchClipboard(query: "PageTest", limit: 200, offset: 400)
        XCTAssertEqual(first.count, 200)
        XCTAssertEqual(second.count, 200)
        XCTAssertEqual(third.count, 51)
        XCTAssertEqual(Set((first + second + third).map(\.id)).count, 451)
        XCTAssertEqual(first.first?.clipboardText, "PageTest 450")
        XCTAssertEqual(third.last?.clipboardText, "PageTest 0")
        XCTAssertTrue(try store.searchClipboard(query: "PageTest", offset: -1).isEmpty)
    }

    func testFileNameImageAndDateFiltersStayExact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "copy",
                         urls: [URL(fileURLWithPath: "/tmp/项目计划.docx")],
                         sourceApplication: "com.apple.finder",
                         detectionMethod: "clipboard",
                         detectedTimeMS: 2_000)
        try store.record(type: "image_copy", urls: [],
                         sourceApplication: nil,
                         detectionMethod: "clipboard_type",
                         detectedTimeMS: 2_001)
        try store.record(type: "copy",
                         urls: [URL(fileURLWithPath: "/tmp/photo.JPG")],
                         sourceApplication: "com.apple.finder",
                         detectionMethod: "clipboard",
                         detectedTimeMS: 2_002)

        XCTAssertEqual(try store.searchClipboard(query: "项目", kind: .files).count, 1)
        XCTAssertEqual(try store.searchClipboard(query: "photo", kind: .images).count, 1)
        XCTAssertEqual(try store.searchClipboard(query: "", kind: .images).count, 2)
        XCTAssertEqual(try store.searchClipboard(query: "", kind: .files).count, 1)
        XCTAssertEqual(try store.searchClipboard(query: "", from: 2_001, to: 2_002).count, 1)
        XCTAssertEqual(try store.searchClipboard(query: "", from: 2_002, to: 2_002).count, 0)
        XCTAssertEqual(try store.searchClipboard(query: "", sourceApplication: "finder").count, 2)
    }

    func testRecentClipboardShelfQueryIsNotCrowdedOutByOtherOperations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("shelf.sqlite"))

        for index in 0..<230 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard",
                             detectedTimeMS: Int64(index + 1),
                             clipboardText: "history \(index)")
        }
        // A general operation timeline can be dominated by paste requests.
        // Those events must not consume the shelf's 200-card budget.
        for index in 0..<240 {
            try store.record(type: "paste_request", urls: [],
                             sourceApplication: nil,
                             detectionMethod: "quartz_shortcut",
                             detectedTimeMS: Int64(index + 1_000))
        }

        let timeline = try store.query(from: 0, to: Int64.max, limit: 200)
        XCTAssertEqual(timeline.count, 200)
        XCTAssertTrue(timeline.allSatisfy { $0.type == "paste_request" })

        let shelf = try store.searchClipboard(query: "", limit: 200)
        XCTAssertEqual(shelf.count, 200)
        XCTAssertTrue(shelf.allSatisfy { $0.type == "text_copy" })
        XCTAssertEqual(shelf.first?.clipboardText, "history 229")
        XCTAssertEqual(shelf.last?.clipboardText, "history 30")
        XCTAssertEqual(Set(shelf.map(\.id)).count, 200)
    }

}
