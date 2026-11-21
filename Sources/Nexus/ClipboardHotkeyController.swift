import AppKit
import Carbon
import SwiftUI
import SlashgrabCore

/// Supported global shortcuts are intentionally opt-in: the default is Off.
/// RegisterEventHotKey fails rather than overriding existing registrations.
@MainActor
final class ClipboardHotkeyController: ObservableObject {
    static let shared = ClipboardHotkeyController()

    enum Preset: String, CaseIterable, Identifiable {
        case off
        case controlOptionV
        case controlShiftSpace
        case controlOptionShiftV
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return localized("Off")
            case .controlOptionV: return "⌃⌥V"
            case .controlShiftSpace: return "⌃⇧Space"
            case .controlOptionShiftV: return "⌃⌥⇧V"
            case .custom: return localized("Custom shortcut")
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .off: return 0
            case .controlOptionV, .controlOptionShiftV: return 9
            case .controlShiftSpace: return 49
            case .custom: return 0
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .off: return 0
            case .controlOptionV: return UInt32(controlKey | optionKey)
            case .controlShiftSpace: return UInt32(controlKey | shiftKey)
            case .controlOptionShiftV: return UInt32(controlKey | optionKey | shiftKey)
            case .custom: return 0
            }
        }
    }

    @Published private(set) var selected: Preset
    @Published private(set) var status = ""
    @Published private(set) var customShortcut: ClipboardShortcutSpecification?
    var onToggle: (@MainActor () -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4E585348 // NXSH
    private let customKey = "nexusClipboardHotkeyCustomShortcut"

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: customKey)
            .flatMap { try? JSONDecoder().decode(
                ClipboardShortcutSpecification.self, from: $0
            ) }
        let loadedCustom = stored?.isValid == true ? stored : nil
        customShortcut = loadedCustom
        let preferred = Preset(rawValue: defaults.string(
            forKey: "nexusClipboardHotkeyPreset") ?? "") ?? .off
        selected = preferred == .custom && loadedCustom == nil ? .off : preferred
    }

    func install() {
        guard eventHandler == nil else { return }
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<ClipboardHotkeyController>
                .fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in controller.onToggle?() }
            return noErr
        }
        let result = InstallEventHandler(
            GetApplicationEventTarget(), handler, 1, &event,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        if result != noErr {
            status = localized("Could not initialize global shortcut handler")
            return
        }
        _ = register(selected)
    }

    @discardableResult
    func setPreset(_ candidate: Preset) -> Bool {
        if candidate == selected { return true }
        let previous = selected
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if register(candidate) {
            selected = candidate
            UserDefaults.standard.set(candidate.rawValue, forKey: "nexusClipboardHotkeyPreset")
            return true
        }
        // A failed/conflicting shortcut must never remove the working one.
        _ = register(previous)
        status = localized("Shortcut unavailable or used by another application")
        return false
    }

    @discardableResult
    func setCustomShortcut(_ candidate: ClipboardShortcutSpecification) -> Bool {
        guard candidate.isValid else {
            status = localized("Select at least two shortcut modifiers")
            return false
        }
        let previous = selected
        let previousCustom = customShortcut
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        customShortcut = candidate
        if register(.custom) {
            selected = .custom
            UserDefaults.standard.set(Preset.custom.rawValue, forKey: "nexusClipboardHotkeyPreset")
            if let data = try? JSONEncoder().encode(candidate) {
                UserDefaults.standard.set(data, forKey: customKey)
            }
            return true
        }
        customShortcut = previousCustom
        _ = register(previous)
        status = localized("Shortcut unavailable or used by another application")
        return false
    }

    private func register(_ preset: Preset) -> Bool {
        guard preset != .off else {
            hotKey = nil
            status = localized("Global clipboard shortcut disabled")
            return true
        }
        let code: UInt32
        let flags: UInt32
        if preset == .custom {
            guard let customShortcut, customShortcut.isValid else {
                status = localized("Configure a custom shortcut first")
                return false
            }
            code = customShortcut.key.physicalKeyCode
            flags = customShortcut.modifiers.reduce(UInt32(0)) { partial, modifier in
                switch modifier {
                case .control: return partial | UInt32(controlKey)
                case .option: return partial | UInt32(optionKey)
                case .shift: return partial | UInt32(shiftKey)
                case .command: return partial | UInt32(cmdKey)
                }
            }
        } else {
            code = preset.keyCode
            flags = preset.modifiers
        }
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: 1)
        let result = RegisterEventHotKey(
            code, flags, hotkeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard result == noErr, let ref else {
            status = localized("Shortcut unavailable or used by another application")
            return false
        }
        hotKey = ref
        status = localized("Global clipboard shortcut enabled")
        return true
    }

    /// The singleton lives until app shutdown. Carbon opaque pointers must
    /// be released on the MainActor, not in a nonisolated Swift 6 deinit.
    func shutdown() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }
}
