import AppKit
import Carbon
import SwiftUI

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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return localized("Off")
            case .controlOptionV: return "⌃⌥V"
            case .controlShiftSpace: return "⌃⇧Space"
            case .controlOptionShiftV: return "⌃⌥⇧V"
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .off: return 0
            case .controlOptionV, .controlOptionShiftV: return 9
            case .controlShiftSpace: return 49
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .off: return 0
            case .controlOptionV: return UInt32(controlKey | optionKey)
            case .controlShiftSpace: return UInt32(controlKey | shiftKey)
            case .controlOptionShiftV: return UInt32(controlKey | optionKey | shiftKey)
            }
        }
    }

    @Published private(set) var selected: Preset
    @Published private(set) var status = ""
    var onToggle: (@MainActor () -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4E585348 // NXSH

    private init() {
        selected = Preset(rawValue: UserDefaults.standard.string(
            forKey: "nexusClipboardHotkeyPreset") ?? "") ?? .off
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
        // Do not silently drop a working shortcut if the new combo conflicts.
        _ = register(previous)
        return false
    }

    private func register(_ preset: Preset) -> Bool {
        guard preset != .off else {
            hotKey = nil
            status = localized("Global clipboard shortcut disabled")
            return true
        }
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: 1)
        let result = RegisterEventHotKey(
            preset.keyCode, preset.modifiers, hotkeyID,
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
