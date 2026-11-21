import AppKit
import Carbon
import CoreGraphics
import SlashgrabCore

final class InputMonitor: @unchecked Sendable {
    private let store: InputStatisticsStore
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mediaMonitor: Any?
    private var hidMonitor: HIDConsumerMonitor?
    private var recentSystemEvents: [String: (source: String, timeMS: Int64)] = [:]
    var onDiagnostic: (@Sendable (InputDiagnosticEvent) -> Void)?

    init(store: InputStatisticsStore) { self.store = store }

    var hasPermission: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    func start() -> Bool {
        guard tap == nil, hasPermission else { return false }
        let eventTypes: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap, monitor.hasPermission { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            monitor.classify(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
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
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let mediaMonitor { NSEvent.removeMonitor(mediaMonitor) }
        hidMonitor?.stop()
        hidMonitor = nil
        recentSystemEvents.removeAll()
        mediaMonitor = nil
        source = nil
        tap = nil
    }

    private func classify(type: CGEventType, event: CGEvent) {
        let timeMS = Self.wallTimeMS(forSystemUptime: TimeInterval(event.timestamp) / 1_000_000_000)
        switch type {
        case .keyDown:
            guard !IsSecureEventInputEnabled() else { return }
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if repeated && !UserDefaults.standard.bool(forKey: "nexusCountKeyRepeats") { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let category = Self.specialKeys[code].map { _ in "keyboard" } ?? "ordinary"
            let name = Self.specialKeys[code] ?? "character_total"
            let timestamp = category == "ordinary" ? (timeMS / 60_000) * 60_000 : timeMS
            store.enqueue(ClassifiedInputEvent(timeMS: timestamp, category: category, name: name, source: "quartz_uptime", isRepeat: repeated))
            if category != "ordinary" {
                onDiagnostic?(InputDiagnosticEvent(timeMS: timeMS, name: name, source: "quartz_uptime", supported: true))
            }
            if let shortcut = Self.shortcutName(code: code, flags: event.flags) {
                store.enqueue(ClassifiedInputEvent(timeMS: timeMS, category: "shortcut", name: shortcut, source: "quartz_uptime", isRepeat: repeated))
                onDiagnostic?(InputDiagnosticEvent(timeMS: timeMS, name: shortcut, source: "quartz_uptime", supported: true))
            }
        case .flagsChanged:
            guard !IsSecureEventInputEnabled() else { return }
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
            category: source == "iohid_function" ? "keyboard" : "system",
            name: name, source: source))
        onDiagnostic?(InputDiagnosticEvent(
            timeMS: timestampMS, name: name, source: source, supported: true))
    }

    private static let specialKeys: [Int64: String] = [53: "escape", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20", 51: "delete", 117: "forward_delete", 36: "return", 48: "tab", 49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "page_up", 121: "page_down"]
    private static let shortcutKeys: [Int64: String] = [8: "c", 9: "v", 7: "x", 6: "z", 48: "tab", 49: "space", 12: "q", 53: "escape"]
    private static func shortcutName(code: Int64, flags: CGEventFlags) -> String? {
        if flags.contains(.maskSecondaryFn), let function = specialKeys[code], function.first == "f",
           Int(function.dropFirst()) != nil {
            return "fn_\(function)"
        }
        if flags.contains(.maskCommand),
           let function = specialKeys[code],
           function.hasPrefix("f"), Int(function.dropFirst()) != nil {
            return flags.contains(.maskShift)
                ? "command_shift_\(function)" : "command_\(function)"
        }
        guard flags.contains(.maskCommand), let key = shortcutKeys[code] else { return nil }
        if key == "z" && flags.contains(.maskShift) { return "command_shift_z" }
        if key == "q" && flags.contains(.maskControl) { return "control_command_q" }
        if key == "escape" && flags.contains(.maskAlternate) { return "command_option_escape" }
        if flags.contains(.maskAlternate) || flags.contains(.maskControl) || flags.contains(.maskShift) { return nil }
        return "command_\(key)"
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
