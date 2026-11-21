import Foundation
import XCTest
@testable import SlashgrabCore

final class OperationRetentionTests: XCTestCase {
    func testPinnedHistorySurvivesAgeAndCountCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try OperationStore(url: root.appendingPathComponent("events.sqlite"))
        for i: Int64 in 1...4 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard",
                             detectedTimeMS: i * 1000, clipboardText: "item \(i)")
        }

        let records = try store.query(from: 0, to: 5000)
        XCTAssertEqual(records.count, 4)
        let oldestPinned = try XCTUnwrap(records.first(where: { $0.detectedTimeMS == 1000 }))
        let pinned = Set([oldestPinned.id])

        // Pinned items do not consume the max-unpinned budget.
        XCTAssertEqual(try store.pruneHistory(keepingNewest: 1, protectedIDs: pinned), 2)
        let remaining = try store.query(from: 0, to: 5000)
        XCTAssertEqual(Set(remaining.map(\.detectedTimeMS)), Set([1000, 4000]))
        XCTAssertEqual(try store.pruneHistory(olderThan: 5000, protectedIDs: pinned), 1)
        XCTAssertEqual(try store.query(from: 0, to: 5000).map(\.id), [oldestPinned.id])

        XCTAssertFalse(try store.deleteOperation(id: "missing"))
        XCTAssertTrue(try store.deleteOperation(id: oldestPinned.id))
        XCTAssertTrue(try store.query(from: 0, to: 5000).isEmpty)
    }

    func testClipboardRetentionNeverDeletesUnrelatedTimelineOperations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("events.sqlite"))

        // These entries share the database but are NOT clipboard history.
        try store.record(type: "paste_request", urls: [],
                         sourceApplication: nil, detectionMethod: "quartz_shortcut",
                         detectedTimeMS: 1000)
        try store.record(type: "file_transfer",
                         urls: [URL(fileURLWithPath: "/tmp/transfer.data")],
                         sourceApplication: "Nexus",
                         detectionMethod: "native_file_operation",
                         detectedTimeMS: 2000, completedTimeMS: 2001)

        for (index, kind) in ["text_copy", "image_copy", "copy"].enumerated() {
            try store.record(type: kind, urls: [],
                             sourceApplication: nil, detectionMethod: "clipboard",
                             detectedTimeMS: Int64(3000 + index * 1000),
                             clipboardText: kind == "text_copy" ? "hello" : nil)
        }

        // A count budget of one must count ONLY clipboard entries, never the
        // older transfer or paste-request entries from the same SQL table.
        XCTAssertEqual(try store.pruneHistory(keepingNewest: 1), 2)
        let afterCount = try store.query(from: 0, to: 6000)
        XCTAssertEqual(Set(afterCount.map(\.type)),
                       Set(["paste_request", "file_transfer", "copy"]))
        XCTAssertEqual(try store.pruneHistory(olderThan: 6000), 1)
        let afterAge = try store.query(from: 0, to: 6000)
        XCTAssertEqual(Set(afterAge.map(\.type)),
                       Set(["paste_request", "file_transfer"]))
    }

    func testRetentionDisabledIsNoOp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("events.sqlite"))
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 123,
                         clipboardText: "sensitive example")
        XCTAssertEqual(try store.pruneHistory(), 0)
        XCTAssertEqual(try store.query(from: 123, to: 124).count, 1)
    }
}
