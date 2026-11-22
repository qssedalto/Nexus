import Foundation
import SQLite3
import XCTest
@testable import NexusCore

final class ClipboardFullTextSearchTests: XCTestCase {
    private func fixture() throws -> (URL, OperationStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try OperationStore(url: directory.appendingPathComponent("history.sqlite"))
        return (directory, store)
    }

    func testOptionalTrigramIndexPreservesExactCJKAndLiteralSearch() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.record(type: "text_copy", urls: [], sourceApplication: "com.example",
                         detectionMethod: "clipboard", detectedTimeMS: 100,
                         clipboardText: "数学分析期中考试 CJK regression test")
        try store.record(type: "copy",
                         urls: [URL(fileURLWithPath: "/tmp/统计学作业和报告.pdf")],
                         sourceApplication: "com.files", detectionMethod: "clipboard",
                         detectedTimeMS: 200)
        XCTAssertFalse(try store.fullTextIndexEnabled())

        let baseline = try ["数学分析", "统计学", "regression", "作业",
                            "%", "_"].map { query in
            try store.searchClipboard(query: query).map(\.id)
        }
        // Apple SQLite may be built without FTS5/trigram. In that case
        // the opt-in operation fails without touching original history.
        do {
            try store.configureFullTextIndex(enabled: true)
        } catch {
            XCTAssertFalse(try store.fullTextIndexEnabled())
            XCTAssertEqual(try store.searchClipboard(query: "数学分析").count, 1)
            throw XCTSkip("System SQLite does not support FTS5 trigram indexing: \(error)")
        }
        XCTAssertTrue(try store.fullTextIndexEnabled())
        for (index, query) in ["数学分析", "统计学", "regression", "作业",
                               "%", "_"].enumerated() {
            XCTAssertEqual(try store.searchClipboard(query: query).map(\.id),
                           baseline[index], query)
        }

        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 300,
                         clipboardText: "最新的分析报告已经完成")
        XCTAssertEqual(try store.searchClipboard(query: "分析报告").count, 1)

        let entry = try XCTUnwrap(store.searchClipboard(query: "数学分析").first)
        XCTAssertTrue(try store.deleteOperation(id: entry.id))
        XCTAssertTrue(try store.searchClipboard(query: "数学分析").isEmpty)

        try store.configureFullTextIndex(enabled: false)
        XCTAssertFalse(try store.fullTextIndexEnabled())
        XCTAssertEqual(try store.searchClipboard(query: "分析报告").count, 1)
        XCTAssertTrue(try store.searchClipboard(query: "数学分析").isEmpty)
    }

    func testIndexedHistorySurvivesRestartAndDropsNoUserRows() throws {
        let (root, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try initial.record(type: "text_copy", urls: [], sourceApplication: nil,
                           detectionMethod: "clipboard", detectedTimeMS: 10,
                           clipboardText: "Nexus Finder fulltext lookup")
        do {
            try initial.configureFullTextIndex(enabled: true)
        } catch {
            throw XCTSkip("FTS5 trigram unavailable: \(error)")
        }
        let reopened = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        XCTAssertTrue(try reopened.fullTextIndexEnabled())
        XCTAssertEqual(try reopened.searchClipboard(query: "fulltext").count, 1)
        try reopened.configureFullTextIndex(enabled: false)
        XCTAssertEqual(try reopened.searchClipboard(query: "fulltext").count, 1)
        XCTAssertEqual(try reopened.query(from: 0, to: 100).count, 1)
        XCTAssertFalse(try reopened.fullTextIndexEnabled())
    }
}
