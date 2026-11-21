import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCardAccentTests: XCTestCase {
    func testColorTagsSurviveRestartAndCascadeOnHistoryDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        var recordID = ""
        do {
            let store = try OperationStore(url: url)
            try store.record(
                type: "text_copy", urls: [],
                sourceApplication: nil, detectionMethod: "clipboard",
                detectedTimeMS: 100, clipboardText: "重要课堂内容"
            )
            recordID = try XCTUnwrap(store.query(from: 0, to: 200).first?.id)
            XCTAssertTrue(try store.cardAccents(operationIDs: [recordID]).isEmpty)
            try store.setCardAccent(.purple, operationID: recordID)
            XCTAssertEqual(
                try store.cardAccents(operationIDs: [recordID])[recordID], .purple
            )
            try store.setCardAccent(.green, operationID: recordID)
            XCTAssertEqual(
                try store.cardAccents(operationIDs: [recordID])[recordID], .green
            )
        }
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(
            try reopened.cardAccents(operationIDs: [recordID])[recordID], .green
        )
        XCTAssertTrue(try reopened.deleteOperation(id: recordID))
        XCTAssertTrue(try reopened.cardAccents(operationIDs: [recordID]).isEmpty)
    }

    func testResetToAutomaticRemovesMarkerAndBatchedLookupIgnoresUnknowns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        try store.record(
            type: "text_copy", urls: [],
            sourceApplication: nil, detectionMethod: "clipboard",
            detectedTimeMS: 1, clipboardText: "demo"
        )
        let id = try XCTUnwrap(store.query(from: 0, to: 3).first?.id)
        try store.setCardAccent(.red, operationID: id)
        XCTAssertEqual(
            try store.cardAccents(operationIDs: [id, id, "missing-id"]).count, 1
        )
        try store.setCardAccent(.automatic, operationID: id)
        XCTAssertTrue(try store.cardAccents(operationIDs: [id]).isEmpty)
        XCTAssertThrowsError(
            try store.setCardAccent(.purple, operationID: UUID().uuidString)
        )
    }

    func testColorMarkersAreCodableAllowlistedValues() throws {
        for accent in ClipboardCardAccent.allCases {
            let data = try JSONEncoder().encode(accent)
            XCTAssertEqual(
                try JSONDecoder().decode(ClipboardCardAccent.self, from: data),
                accent
            )
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ClipboardCardAccent.self, from: Data("\"arbitrary-css\"".utf8)
            )
        )
    }
}
