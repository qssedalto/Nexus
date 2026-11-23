import Foundation
import Darwin
import IOKit.hid
import NexusCore

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
        // Match consumer-control and keyboard devices, but accept only
        // consumer usages and F21–F24 element reports. No text key logging.
        IOHIDManagerSetDeviceMatchingMultiple(hid, [
            [
                kIOHIDDeviceUsagePageKey as String: 0x0C
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x01,
                kIOHIDDeviceUsageKey as String: 0x06
            ]
        ] as CFArray)
        IOHIDManagerSetInputValueMatchingMultiple(hid, [
            [kIOHIDElementUsagePageKey as String: 0x0C],
            [kIOHIDElementUsagePageKey as String: 0x07]
        ] as CFArray)
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
        guard page == 0x0C || page == 0x07 else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        // Only Function F21–F24 from the Keyboard page. Do not retain
        // ordinary key usages, HID scan sequences or password keystrokes.
        let keyName = page == 0x0C
            ? HIDConsumerUsage.name(for: usage)
            : HIDConsumerUsage.functionName(forKeyboardUsage: usage)
        guard let keyName else { return }
        let physicalKey = "\(IOHIDElementGetDevice(element)):\(page):\(usage)"
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        if !pressed {
            pressedUsages.remove(physicalKey)
            return
        }
        // Count the rising edge, not every HID report while held.
        guard pressedUsages.insert(physicalKey).inserted else { return }
        let timestampMS = Self.timestamp(for: IOHIDValueGetTimeStamp(value))
        let source = Self.sourceName(
            for: IOHIDElementGetDevice(element),
            category: page == 0x0C ? "iohid_consumer" : "iohid_function"
        )
        eventHandler(keyName, timestampMS, source)
    }

    /// Vendor/product IDs describe a *device model*, not an individual
    /// physical device. A stable nonzero location ID can distinguish two
    /// attached models sharing vendor/product without retaining serials.
    /// No UDID, serial number, BT MAC address or typed text is collected.
    private static func sourceName(for device: IOHIDDevice, category: String) -> String {
        let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = productName.flatMap { name -> String? in
            let cleaned = String(name.filter {
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }.prefix(64))
            return cleaned.isEmpty ? nil : cleaned
        }
        let suffix = displayName.map { ":name:" + $0 } ?? ""
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        guard let vendor, let product else {
            return category + ":unknown_device" + suffix
        }
        let prefix = "\(category):vendor_\(vendor)_product_\(product)"
        if let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue,
           location > 0 {
            return prefix + "_location_\(location)" + suffix
        }
        return prefix + "_location_unknown" + suffix
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
