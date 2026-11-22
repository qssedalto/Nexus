import Foundation

/// A layout-independent, testable interpretation of macOS virtual keycodes.
/// Never serializes translated characters, key-up sequences, or raw text.
/// A chord name describes observed modifiers and positions, NOT confirmation
/// that an app or system shortcut action was executed.
public enum KeyboardEventClassifier {
    public enum Modifier: String, CaseIterable, Hashable, Sendable {
        case control, option, command, shift, fn
    }

    public static let specialKeys: [Int64: String] = [53: "escape", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20", 51: "delete", 117: "forward_delete", 36: "return", 48: "tab", 49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "page_up", 121: "page_down"]
    // ANSI physical positions, not translated text. A non-US layout may
    // print a different character on the same key.
    public static let physicalKeys: [Int64: String] = [
        0:"a", 1:"s", 2:"d", 3:"f", 4:"h", 5:"g", 6:"z", 7:"x", 8:"c", 9:"v", 11:"b",
        12:"q", 13:"w", 14:"e", 15:"r", 16:"y", 17:"t", 18:"1", 19:"2", 20:"3",
        21:"4", 22:"6", 23:"5", 25:"9", 26:"7", 28:"8", 29:"0", 31:"o", 32:"u",
        34:"i", 35:"p", 37:"l", 38:"j", 40:"k", 41:"semicolon", 43:"comma",
        44:"slash", 45:"n", 46:"m", 47:"period",
        24:"equal", 27:"minus", 30:"right_bracket", 33:"left_bracket",
        39:"quote", 42:"backslash", 50:"grave",
        65:"keypad_decimal", 67:"keypad_multiply", 69:"keypad_plus",
        71:"keypad_clear", 75:"keypad_divide", 76:"keypad_enter",
        78:"keypad_minus", 81:"keypad_equal",
        82:"keypad_0", 83:"keypad_1", 84:"keypad_2",
        85:"keypad_3", 86:"keypad_4", 87:"keypad_5",
        88:"keypad_6", 89:"keypad_7", 91:"keypad_8", 92:"keypad_9"
    ]
    // Every observable special key can be part of an observed chord.
    private static let shortcutKeys: [Int64: String] = physicalKeys.merging(specialKeys) {
        current, _ in current
    }
    public static func physicalKeyName(code: Int64, shifted: Bool) -> String {
        let name = physicalKeys[code].map { "key_" + $0 } ?? "character_total"
        return shifted ? "shift_" + name : name
    }

    public static func shortcutName(
        code: Int64, modifiers: Set<Modifier>
    ) -> String? {
        guard let key = shortcutKeys[code],
              modifiers.contains(where: { $0 != .shift }) else { return nil }
        let names = Modifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.rawValue)
        return (names + [key]).joined(separator: "_")
    }
}
