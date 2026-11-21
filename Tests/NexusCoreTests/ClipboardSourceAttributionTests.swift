import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardSourceAttributionTests: XCTestCase {
    func testObservedForegroundIsNeverCalledVerifiedOrigin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "text_copy", urls: [],
                         sourceApplication: "com.apple.Safari",
                         detectionMethod: "clipboard_frontmost_observed",
                         detectedTimeMS: 1, clipboardText: "test")
        try store.record(type: "text_copy", urls: [],
                         sourceApplication: "com.example.KnownSource",
                         detectionMethod: "external_reported",
                         detectedTimeMS: 2, clipboardText: "test")
        try store.record(type: "text_copy", urls: [],
                         sourceApplication: nil,
                         detectionMethod: "clipboard",
                         detectedTimeMS: 3, clipboardText: "test")
        let rows = try store.query(from: 0, to: 4)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(ClipboardSourceAttribution.classify(rows[2]),
                       .observedForeground(bundleID: "com.apple.Safari"))
        XCTAssertEqual(ClipboardSourceAttribution.classify(rows[1]),
                       .reported(bundleID: "com.example.KnownSource"))
        XCTAssertEqual(ClipboardSourceAttribution.classify(rows[0]), .unknown)
    }
}
