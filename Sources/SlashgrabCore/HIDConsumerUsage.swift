import Foundation

/// Public USB HID Consumer Page (0x0C) usages. Only exact, documented
/// meanings are mapped. Unknown vendor-specific usages are NOT guessed.
public enum HIDConsumerUsage {
    public static func name(for usage: Int) -> String? {
        switch usage {
        case 0x30: return "power"
        case 0x32: return "sleep"
        case 0x6F: return "brightness_up"
        case 0x70: return "brightness_down"
        case 0x79: return "keyboard_light_up"
        case 0x7A: return "keyboard_light_down"
        case 0xB2: return "media_record"
        case 0xB3: return "fast_forward"
        case 0xB4: return "rewind"
        case 0xB5: return "next"
        case 0xB6: return "previous"
        case 0xB7: return "stop"
        case 0xB8: return "eject"
        case 0xCD: return "play_pause"
        case 0xE2: return "mute"
        case 0xE9: return "volume_up"
        case 0xEA: return "volume_down"
        case 0x192: return "calculator"
        case 0x19E: return "screensaver"
        case 0x221: return "spotlight_search"
        case 0x29D: return "fn"
        default: return nil
        }
    }

    /// HID Keyboard Page (0x07) has F21–F24 usage IDs 0x70–0x73.
    /// Other keyboard usages are deliberately discarded to avoid raw typing.
    public static func functionName(forKeyboardUsage usage: Int) -> String? {
        guard (0x70...0x73).contains(usage) else { return nil }
        return "f\(usage - 0x70 + 21)"
    }

    /// Known independent system-defined key type codes in macOS NSEvent
    /// (subtype 8). Do not infer that F3 automatically means Mission Control.
    public static func macSystemKeyName(for type: Int) -> String? {
        switch type {
        case 0: return "volume_up"
        case 1: return "volume_down"
        case 2: return "brightness_up"
        case 3: return "brightness_down"
        case 7: return "mute"
        case 16: return "play_pause"
        case 17: return "next"
        case 18: return "previous"
        case 19: return "fast_forward"
        case 20: return "rewind"
        case 21: return "keyboard_light_up"
        case 22: return "keyboard_light_down"
        case 23: return "keyboard_light_toggle"
        default: return nil
        }
    }
}

public struct InputDiagnosticEvent: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timeMS: Int64
    public let name: String
    public let source: String
    public let supported: Bool
    public init(timeMS: Int64, name: String, source: String, supported: Bool) {
        id = UUID()
        self.timeMS = timeMS
        self.name = name
        self.source = source
        self.supported = supported
    }
}
