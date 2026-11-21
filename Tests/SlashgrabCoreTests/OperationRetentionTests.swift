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
