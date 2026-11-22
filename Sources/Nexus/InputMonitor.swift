import AppKit
import Carbon
import CoreGraphics
import NexusCore

enum ClipboardShortcutObservation: Sendable {
    case copy, paste, pasteRecorded
}

final class InputMonitor: InputEventListening, @unchecked Sendable {
    private let store: InputStatisticsStore
    private let operationStore = OperationStore.shared()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var startFailed = false
    private(set) var receivedEvents = false
    private var mediaMonitor: Any?
    private var hidMonitor: HIDConsumerMonitor?
    private var recentSystemEvents: [String: (source: String, timeMS: Int64)] = [:]
    var onDiagnostic: (@Sendable (InputDiagnosticEvent) -> Void)?
    var onClipboardShortcut: (@Sendable (ClipboardShortcutObservation) -> Void)?

    init(store: InputStatisticsStore) { self.store = store }

    var tapState: InputTapState {
        guard let tap else { return startFailed ? .creationFailed : .stopped }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap) ? .listening : .disabled
    }

    func start() {
        guard tapState != .listening else { return }
        stop()
        let eventTypes: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap, CGPreflightListenEventAccess() {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            if (type == .keyDown || type == .flagsChanged) && IsSecureEventInputEnabled() {
                return Unmanaged.passUnretained(event)
            }
            monitor.receivedEvents = true
            monitor.classify(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            startFailed = true
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mediaMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.classifySystemDefined(event)
        }
        let hid = HIDConsumerMonitor { [weak self] name, timestampMS, source in
            self?.recordSystemEvent(name: name, timestampMS: timestampMS, source: source)
        }
        if hid.start() { hidMonitor = hid }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
        hidMonitor?.stop()
        hidMonitor = nil
        recentSystemEvents.removeAll()
        mediaMonitor = nil
        source = nil
        tap = nil
        startFailed = false
        receivedEvents = false
    }

    private func classify(type: CGEventType, event: CGEvent) {
        let timeMS = Self.wallTimeMS(forSystemUptime: TimeInterval(event.timestamp) / 1_000_000_000)
        switch type {
        case .keyDown:
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if repeated && !UserDefaults.standard.bool(forKey: "nexusCountKeyRepeats") { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let category = Self.specialKeys[code].map { _ in "keyboard" } ?? "ordinary"
            // Count physical keys by minute. Do not inspect event text or
            // retain a character stream, including during Secure Input.
            let name = Self.specialKeys[code] ?? Self.physicalKeyName(
                code: code, shifted: event.flags.contains(.maskShift))
            let timestamp = category == "ordinary" ? (timeMS / 60_000) * 60_000 : timeMS
            store.enqueue(ClassifiedInputEvent(timeMS: timestamp, category: category, name: name, source: "quartz_uptime", isRepeat: repeated))
            if category != "ordinary" {
                onDiagnostic?(InputDiagnosticEvent(timeMS: timeMS, name: name, source: "quartz_uptime", supported: true))
            }
            if let shortcut = Self.shortcutName(code: code, flags: event.flags) {
                store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "shortcut", name: shortcut, source: "quartz_uptime", isRepeat: repeated))
                onDiagnostic?(InputDiagnosticEvent(timeMS: timeMS, name: shortcut, source: "quartz_uptime", supported: true))
                // This observes a keyboard request only. macOS provides no
                // reliable third-party confirmation that a paste succeeded.
                // It is independently opt-in and never reads clipboard text.
                if shortcut == "command_c", !repeated {
                    onClipboardShortcut?(.copy)
                }
                if shortcut == "command_v", !repeated,
                   UserDefaults.standard.bool(forKey: "nexusMonitorPasteRequests") {
                    onClipboardShortcut?(.paste)
                    let recordStore = operationStore
                    let observedMS = Int64(Date().timeIntervalSince1970 * 1000)
                    let onClipboardShortcut = onClipboardShortcut
                    Task.detached(priority: .utility) {
                        guard let recordStore, (try? recordStore.record(
                            type: "paste_request", urls: [],
                            sourceApplication: nil,
                            detectionMethod: "quartz_shortcut",
                            eventTimeMS: timeMS, detectedTimeMS: observedMS
                        )) != nil else { return }
                        onClipboardShortcut?(.pasteRecorded)
                    }
                }
            }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard let name = Self.modifiers[code] else { return }
            if name == "caps_lock" || event.flags.contains(Self.modifierFlag(for: name)) {
                store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "modifier", name: name, source: "quartz_uptime"))
                onDiagnostic?(InputDiagnosticEvent(timeMS: timeMS, name: name, source: "quartz_uptime", supported: true))
                if name == "caps_lock" {
                    store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "system", name: event.flags.contains(.maskAlphaShift) ? "caps_lock_on" : "caps_lock_off", source: "quartz_uptime"))
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let name = [0: "mouse_left", 1: "mouse_right", 2: "mouse_middle", 3: "mouse_back", 4: "mouse_forward"][button] ?? "mouse_extra_\(button)"
            store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "mouse", name: name, source: "quartz_uptime"))
        case .scrollWheel:
            let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            if vertical != 0 { store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "scroll", name: vertical > 0 ? "scroll_up" : "scroll_down", source: "quartz_uptime")) }
            if horizontal != 0 { store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "scroll", name: horizontal > 0 ? "scroll_right" : "scroll_left", source: "quartz_uptime")) }
        default: break
        }
    }

    private func classifySystemDefined(_ event: NSEvent) {
        // Secure Event Input is enforced consistently for Quartz, AppKit
        // media keys and HID callbacks. Keyboard diagnostic sampling stops too.
        guard !IsSecureEventInputEnabled() else { return }
        guard event.subtype.rawValue == 8 else { return }
        let keyType = (event.data1 >> 16) & 0xffff
        let keyState = (event.data1 >> 8) & 0xff
        guard keyState == 0x0A else { return }
        guard let name = HIDConsumerUsage.macSystemKeyName(for: keyType) else {
            onDiagnostic?(InputDiagnosticEvent(
                timeMS: Self.wallTimeMS(forSystemUptime: event.timestamp),
                name: "unrecognized_system_key_\(keyType)",
                source: "appkit_system_defined", supported: false))
            return
        }
        recordSystemEvent(name: name,
                          timestampMS: Self.wallTimeMS(forSystemUptime: event.timestamp),
                          source: "appkit_system_defined")
    }

    /// A single physical Consumer key can surface via both HID and
    /// NSEvent.systemDefined. Keep the first observation; suppress only
    /// cross-source duplicates within 80ms, never two presses from one source.
    private func recordSystemEvent(name: String, timestampMS: Int64, source: String) {
        // The HID monitor can run independently of the Quartz event tap.
        // Never count or diagnose keys while Secure Event Input is active.
        guard !IsSecureEventInputEnabled() else { return }
        if let previous = recentSystemEvents[name],
           previous.source != source,
           abs(timestampMS - previous.timeMS) < 80 {
            return
        }
        recentSystemEvents[name] = (source: source, timeMS: timestampMS)
        if recentSystemEvents.count > 60 {
            recentSystemEvents = recentSystemEvents.filter {
                abs(timestampMS - $0.value.timeMS) < 1000
            }
        }
        store.enqueue(ClassifiedInputEvent(
            timeMS: timestampMS,
            category: source.hasPrefix("iohid_function") ? "keyboard" : "system",
            name: name, source: source))
        onDiagnostic?(InputDiagnosticEvent(
            timeMS: timestampMS, name: name, source: source, supported: true))
    }

    private static let specialKeys: [Int64: String] = [53: "escape", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20", 51: "delete", 117: "forward_delete", 36: "return", 48: "tab", 49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "page_up", 121: "page_down"]
    // ANSI physical positions, not translated text. A non-US layout may
    // print a different character on the same key.
    private static let physicalKeys: [Int64: String] = [
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
    static func physicalKeyName(code: Int64, shifted: Bool) -> String {
        let name = physicalKeys[code].map { "key_" + $0 } ?? "character_total"
        return shifted ? "shift_" + name : name
    }
    static func shortcutName(code: Int64, flags: CGEventFlags) -> String? {
        guard let key = shortcutKeys[code] else { return nil }
        let modifiers: [(CGEventFlags, String)] = [
            (.maskControl, "control"), (.maskAlternate, "option"),
            (.maskCommand, "command"), (.maskShift, "shift"),
            (.maskSecondaryFn, "fn")
        ]
        let active = modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil }
        // Shift-only typing is not an application shortcut; Fn and other
        // modifier chords are observable even when their action is unknown.
        guard active.contains(where: { $0 != "shift" }) else { return nil }
        return (active + [key]).joined(separator: "_")
    }

    private static func wallTimeMS(forSystemUptime eventUptime: TimeInterval) -> Int64 {
        let now = Date().timeIntervalSince1970
        let elapsed = ProcessInfo.processInfo.systemUptime - eventUptime
        // Quartz and AppKit timestamps are uptime based; an implausible delta means the
        // device or API uses a different clock, so detection time is the honest fallback.
        let estimate = (0...10).contains(elapsed) ? now - elapsed : now
        return Int64(estimate * 1000)
    }
    private static let modifiers: [Int64: String] = [55: "left_command", 54: "right_command", 58: "left_option", 61: "right_option", 59: "left_control", 62: "right_control", 56: "left_shift", 60: "right_shift", 57: "caps_lock", 63: "fn"]
    private static func modifierFlag(for name: String) -> CGEventFlags {
        if name.contains("command") { return .maskCommand }
        if name.contains("option") { return .maskAlternate }
        if name.contains("control") { return .maskControl }
        if name.contains("shift") { return .maskShift }
        if name == "fn" { return .maskSecondaryFn }
        return .maskAlphaShift
    }
}
