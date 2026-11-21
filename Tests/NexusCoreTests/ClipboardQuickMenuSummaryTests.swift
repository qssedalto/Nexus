import Foundation
import XCTest
@testable import NexusCore

final class ClipboardQuickMenuSummaryTests: XCTestCase {
    func testRecentMenuOrderingAndBoundedTitlesForUnicodeAndNewlines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(
            url: root.appendingPathComponent("history.sqlite")
        )
        for i in 1...8 {
            try store.record(
                type: "text_copy", urls: [], sourceApplication: nil,
                detectionMethod: "clipboard", detectedTimeMS: Int64(i),
                clipboardText: "这是第 \(i) 条\n剪贴板内容"
            )
        }
        let rows = try store.query(from: 0, to: 20)
        let recent = ClipboardQuickMenuSummary.recent(from: rows)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first?.detectedTimeMS, 8)
        XCTAssertEqual(recent.last?.detectedTimeMS, 4)
        let title = ClipboardQuickMenuSummary.title(
            for: try XCTUnwrap(recent.first), maximumCharacters: 15
        )
        XCTAssertFalse(title.contains("\n"))
        XCTAssertLessThanOrEqual(title.count, 15)
    }

    func testMenuNeverClaimsImagePixelsOrFullFileText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        try store.record(type: "image_copy", urls: [],
                         sourceApplication: nil, detectionMethod: "clipboard",
                         detectedTimeMS: 1)
        try store.record(
            type: "copy",
            urls: [URL(fileURLWithPath: "/private/tmp/secret-report.pdf")],
            sourceApplication: nil, detectionMethod: "clipboard",
            detectedTimeMS: 2
        )
        let rows = try store.query(from: 0, to: 3)
        XCTAssertEqual(ClipboardQuickMenuSummary.title(for: rows[0]),
                       "secret-report.pdf")
        XCTAssertEqual(ClipboardQuickMenuSummary.title(for: rows[1]),
                       "Copied image")
    }
}
