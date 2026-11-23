import CoreGraphics
import Testing
@testable import Nexus

struct InputKeyClassificationTests {
    @Test func physicalKeyCountsDoNotReadTranslatedCharacters() {
        #expect(InputMonitor.physicalKeyName(code: 0, shifted: false) == "key_a")
        #expect(InputMonitor.physicalKeyName(code: 18, shifted: true) == "shift_key_1")
        #expect(InputMonitor.physicalKeyName(code: 999, shifted: false) == "character_total")
        #expect(InputMonitor.physicalKeyName(code: 24, shifted: false) == "key_equal")
        #expect(InputMonitor.physicalKeyName(code: 39, shifted: true) == "shift_key_quote")
        #expect(InputMonitor.physicalKeyName(code: 82, shifted: false) == "key_keypad_0")
        #expect(InputMonitor.physicalKeyName(code: 91, shifted: false) == "key_keypad_8")
    }

    @Test func combinedShortcutsKeepEachModifier() {
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        #expect(InputMonitor.shortcutName(code: 18, flags: flags) == "control_option_command_1")
        #expect(InputMonitor.shortcutName(code: 46, flags: flags) == "control_option_command_m")
        #expect(InputMonitor.shortcutName(code: 8, flags: [.maskCommand]) == "command_c")
        #expect(InputMonitor.shortcutName(code: 9, flags: [.maskCommand]) == "command_v")
        #expect(InputMonitor.shortcutName(code: 0, flags: [.maskShift]) == nil)
        #expect(InputMonitor.shortcutName(code: 82, flags: [.maskCommand]) == "command_keypad_0")
        #expect(InputMonitor.shortcutName(code: 105, flags: [.maskCommand]) == "command_f13")
        #expect(InputMonitor.shortcutName(code: 122, flags: [.maskSecondaryFn]) == "fn_f1")
        #expect(InputMonitor.shortcutName(code: 122, flags: [.maskCommand, .maskSecondaryFn]) == "command_fn_f1")
    }
}
