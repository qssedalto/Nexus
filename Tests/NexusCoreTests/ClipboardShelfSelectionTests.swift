import XCTest
@testable import NexusCore

final class ClipboardShelfSelectionTests: XCTestCase {
    func testPreservesSelectionWhenStillVisible() {
        XCTAssertEqual(
            ClipboardShelfSelection.visibleSelection(
                currentID: "second", visibleIDs: ["first", "second", "third"]),
            "second"
        )
    }

    func testSelectsFirstMatchingCardAfterSearchOrCollectionSwitch() {
        XCTAssertEqual(
            ClipboardShelfSelection.visibleSelection(
                currentID: "old", visibleIDs: ["match", "another"]),
            "match"
        )
        XCTAssertEqual(
            ClipboardShelfSelection.visibleSelection(
                currentID: nil, visibleIDs: ["collection-first"]),
            "collection-first"
        )
    }

    func testEmptyResultsClearStaleSelection() {
        XCTAssertNil(
            ClipboardShelfSelection.visibleSelection(
                currentID: "removed", visibleIDs: [])
        )
    }
}
