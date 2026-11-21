import Foundation

/// This shortcut is active only while the clipboard shelf has keyboard
/// focus. It does not register an additional system-wide hotkey.
public enum ClipboardCollectionSwitchModifier: String, Codable, CaseIterable, Sendable {
    case command
    case controlOption

    public var description: String {
        switch self {
        case .command: return "⌘ + 0…9"
        case .controlOption: return "⌃⌥ + 0…9"
        }
    }
}

public enum ClipboardCollectionShortcut {
    /// 0 shows all history; 1–9 select the first nine named collections.
    /// ID ordering is supplied by the same persisted collection list shown
    /// in the shelf's Picker and may change only on collection edits.
    public static func target(
        for characters: String, collectionIDs: [String]
    ) -> String? {
        guard characters.utf16.count == 1,
              let digit = characters.first?.wholeNumberValue,
              (0...9).contains(digit) else { return nil }
        if digit == 0 { return "" }
        guard collectionIDs.indices.contains(digit - 1) else { return nil }
        return collectionIDs[digit - 1]
    }
}
