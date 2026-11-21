import XCTest
@testable import NexusCore

final class ClipboardCollectionShortcutTests: XCTestCase {
    func testZeroMeansAllAndDigitsUseDisplayedCollectionOrder() {
        let ids = (1...9).map { "collection-\($0)" }
        XCTAssertEqual(ClipboardCollectionShortcut.target(
            for: "0", collectionIDs: ids), "")
        XCTAssertEqual(ClipboardCollectionShortcut.target(
            for: "1", collectionIDs: ids), "collection-1")
        XCTAssertEqual(ClipboardCollectionShortcut.target(
            for: "9", collectionIDs: ids), "collection-9")
        XCTAssertNil(ClipboardCollectionShortcut.target(
            for: "8", collectionIDs: ["only-1"]))
    }

    func testUnrelatedKeyPressesAreIgnored() {
        let ids = ["first", "second"]
        for key in ["", "q", "F1", "11", "⌘1", "a1"] {
            XCTAssertNil(ClipboardCollectionShortcut.target(
                for: key, collectionIDs: ids), key)
        }
    }

    func testModifierChoiceSurvivesPreferenceEncoding() throws {
        for mode in ClipboardCollectionSwitchModifier.allCases {
            let encoded = try JSONEncoder().encode(mode)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    ClipboardCollectionSwitchModifier.self, from: encoded),
                mode
            )
        }
        XCTAssertEqual(
            ClipboardCollectionSwitchModifier.controlOption.description, "⌃⌥ + 0…9"
        )
    }
}
