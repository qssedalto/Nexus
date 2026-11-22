import Carbon
import Foundation
import NexusCore

/// The stored event name is always a layout-independent physical position.
/// This adapter resolves a human-readable glyph from the CURRENT keyboard
/// layout only when the statistics UI needs to display one. It never reads
/// CGEvent text, retains a keystroke sequence, or writes output to the DB.
enum KeyboardLayoutLabel {
    static func glyph(for physicalName: String, shifted: Bool) -> String? {
        // Preserve an explicit numpad identity rather than attributing its
        // behavior to a layout-dependent printable character.
        guard !physicalName.hasPrefix("keypad_"),
              let code = KeyboardEventClassifier.physicalKeys.first(
                where: { $0.value == physicalName }
              )?.key, code >= 0, code <= Int64(UInt16.max),
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData
              ) else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let rawBytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(rawBytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let modifierState: UInt32 = shifted ? UInt32(shiftKey >> 8) & 0xff : 0
        let result = UCKeyTranslate(
            layout, UInt16(code), UInt16(kUCKeyActionDisplay),
            modifierState, UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState, characters.count, &actualLength, &characters
        )
        guard result == noErr, actualLength > 0,
              actualLength <= characters.count else { return nil }
        let glyph = String(utf16CodeUnits: characters, count: actualLength)
        // A key label, never a synthesized multiline typed string.
        guard glyph.count <= 4, !glyph.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return glyph
    }
}
