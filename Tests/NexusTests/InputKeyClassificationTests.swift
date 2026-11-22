import CoreGraphics
import Testing
@testable import Nexus

struct InputKeyClassificationTests {
    @Test func physicalKeyCountsDoNotReadTranslatedCharacters() {
        #expect(InputMonitor.physicalKeyName(code: 0, shifted: false) == "key_a")
        #expect(InputMonitor.physicalKeyName(code: 18, shifted: true) == "shift_key_1")
        #expect(InputMonitor.physicalKeyName(code: 999, shifted: false) == "character_total")
    }

    @Test func combinedShortcutsKeepEachModifier() {
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        #expect(InputMonitor.shortcutName(code: 18, flags: flags) == "control_option_command_1")
        #expect(InputMonitor.shortcutName(code: 46, flags: flags) == "control_option_command_m")
        #expect(InputMonitor.shortcutName(code: 8, flags: [.maskCommand]) == "command_c")
        #expect(InputMonitor.shortcutName(code: 9, flags: [.maskCommand]) == "command_v")
        #expect(InputMonitor.shortcutName(code: 0, flags: [.maskShift]) == nil)
    }
}
