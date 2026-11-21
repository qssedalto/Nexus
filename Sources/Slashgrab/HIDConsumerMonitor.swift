import Foundation
import Darwin
import IOKit.hid
import SlashgrabCore

/// Passive USB HID consumer-control observer. It neither opens exclusive
/// devices nor sets report values, remaps keys, diverts controls or reads text.
/// Quartz remains responsible for ordinary keyboard/mouse input; this monitor
/// only observes the Consumer (0x0C) usage page for top-row/media controls.
final class HIDConsumerMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable (_ name: String, _ timestampMS: Int64, _ source: String) -> Void
    private var manager: IOHIDManager?
    private let eventHandler: EventHandler
    private var pressedUsages = Set<String>()

    init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    @discardableResult
    func start() -> Bool {
        guard manager == nil else { return true }
        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hid, [
            kIOHIDDeviceUsagePageKey as String: 0x0C
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatching(hid, [
            kIOHIDElementUsagePageKey as String: 0x0C
        ] as CFDictionary)
        let callback: IOHIDValueCallback = { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let monitor = Unmanaged<HIDConsumerMonitor>
                .fromOpaque(context).takeUnretainedValue()
            monitor.received(value)
        }
        IOHIDManagerRegisterInputValueCallback(
            hid, callback, Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        guard IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
            )
            return false
        }
        manager = hid
        return true
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        pressedUsages.removeAll()
        self.manager = nil
    }

    private func received(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        guard page == 0x0C else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        let physicalKey = "\(Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque()):\(usage)"
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        if !pressed {
            pressedUsages.remove(physicalKey)
            return
        }
        // Count the rising edge, not every HID report while held.
        guard pressedUsages.insert(physicalKey).inserted else { return }
        guard let name = HIDConsumerUsage.name(for: usage) else { return }
        let timestampMS = Self.timestamp(for: IOHIDValueGetTimeStamp(value))
        eventHandler(name, timestampMS, "iohid_consumer")
    }

    private static func timestamp(for rawTicks: UInt64) -> Int64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = mach_absolute_time()
        guard info.denom != 0, rawTicks <= now else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        let seconds = Double(now - rawTicks) * Double(info.numer)
            / Double(info.denom) / 1_000_000_000
        guard (0...10).contains(seconds) else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        return Int64((Date().timeIntervalSince1970 - seconds) * 1000)
    }
}
