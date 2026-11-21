import Foundation

/// Hardware key selection for Carbon RegisterEventHotKey. Physical US ANSI
/// key positions are used; user-facing text must not claim layout-aware keys.
public enum ClipboardShortcutKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0, digit1, digit2, digit3, digit4
    case digit5, digit6, digit7, digit8, digit9
    case space
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var id: String { rawValue }

    public var physicalKeyCode: UInt32 {
        switch self {
        case .a: return 0
        case .s: return 1
        case .d: return 2
        case .f: return 3
        case .h: return 4
        case .g: return 5
        case .z: return 6
        case .x: return 7
        case .c: return 8
        case .v: return 9
        case .b: return 11
        case .q: return 12
        case .w: return 13
        case .e: return 14
        case .r: return 15
        case .y: return 16
        case .t: return 17
        case .digit1: return 18
        case .digit2: return 19
        case .digit3: return 20
        case .digit4: return 21
        case .digit6: return 22
        case .digit5: return 23
        case .digit9: return 25
        case .digit7: return 26
        case .digit8: return 28
        case .digit0: return 29
        case .o: return 31
        case .u: return 32
        case .i: return 34
        case .p: return 35
        case .l: return 37
        case .j: return 38
        case .k: return 40
        case .n: return 45
        case .m: return 46
        case .space: return 49
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        }
    }

    public var displayName: String {
        switch self {
        case .space: return "Space"
        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"
        default: return rawValue.uppercased()
        }
    }
}

public enum ClipboardShortcutModifier: String, Codable, CaseIterable, Sendable {
    case control, option, shift, command
}

/// A full user-editable shortcut; cannot accidentally replace a working
/// shortcut with a bare letter or a single-system-modifier combination.
public struct ClipboardShortcutSpecification: Codable, Sendable, Equatable {
    public let key: ClipboardShortcutKey
    public let modifiers: Set<ClipboardShortcutModifier>

    public init(key: ClipboardShortcutKey, modifiers: Set<ClipboardShortcutModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public var isValid: Bool { modifiers.count >= 2 }

    public var displayName: String {
        let symbols: [(ClipboardShortcutModifier, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ]
        return symbols.filter { modifiers.contains($0.0) }
            .map(\.1).joined() + key.displayName
    }
}
