import XCTest
@testable import NexusCore

final class KeyboardEventClassifierTests: XCTestCase {
    func testPhysicalANSIPositionsNeverClaimToBeTypedCharacters() {
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 0, shifted: false), "key_a")
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 18, shifted: true), "shift_key_1")
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 82, shifted: false), "key_keypad_0")
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 39, shifted: true), "shift_key_quote")
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 999, shifted: false), "character_total")
        XCTAssertEqual(KeyboardEventClassifier.physicalKeyName(code: 999, shifted: true), "character_total")
    }

    func testGenericModifierOrderAndSystemFunctionKeys() {
        typealias Classifier = KeyboardEventClassifier
        XCTAssertEqual(Classifier.shortcutName(code: 18, modifiers: [.command, .shift]),
                       "command_shift_1")
        XCTAssertEqual(Classifier.shortcutName(code: 0, modifiers: [.shift, .control]),
                       "control_shift_a")
        XCTAssertEqual(Classifier.shortcutName(code: 82, modifiers: [.command]),
                       "command_keypad_0")
        XCTAssertEqual(Classifier.shortcutName(code: 122, modifiers: [.fn]), "fn_f1")
        XCTAssertEqual(Classifier.shortcutName(code: 105, modifiers: [.fn, .option]),
                       "option_fn_f13")
        XCTAssertEqual(Classifier.shortcutName(code: 20, modifiers: [
            .fn, .shift, .control, .option, .command
        ]), "control_option_command_shift_fn_3")
    }

    func testShiftOnlyTypingIsNotAnApplicationShortcut() {
        XCTAssertNil(KeyboardEventClassifier.shortcutName(code: 0, modifiers: [.shift]))
        XCTAssertNil(KeyboardEventClassifier.shortcutName(code: 18, modifiers: []))
        XCTAssertNil(KeyboardEventClassifier.shortcutName(code: 999, modifiers: [.command]))
    }

    func testSpecialKeysCanBeClassifiedWithoutGeneratingText() {
        XCTAssertEqual(KeyboardEventClassifier.specialKeys[122], "f1")
        XCTAssertEqual(KeyboardEventClassifier.specialKeys[90], "f20")
        XCTAssertEqual(KeyboardEventClassifier.specialKeys[117], "forward_delete")
        XCTAssertEqual(KeyboardEventClassifier.shortcutName(code: 123, modifiers: [.command]),
                       "command_left")
    }
}
