import ApplicationServices
import NexusCore

protocol InputPermissionProviding {
    func canListen() -> Bool
    func requestListening() -> Bool
    func canUseAccessibility() -> Bool
    func requestAccessibility() -> Bool
}

struct SystemInputPermissions: InputPermissionProviding {
    func canListen() -> Bool { CGPreflightListenEventAccess() }
    func requestListening() -> Bool { CGRequestListenEventAccess() }
    func canUseAccessibility() -> Bool { AXIsProcessTrusted() }
    func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

enum InputTapState: String {
    case stopped, creationFailed, disabled, listening
}

protocol InputEventListening: AnyObject {
    var tapState: InputTapState { get }
    var receivedEvents: Bool { get }
    func start()
    func stop()
}

struct InputPermissionState: Equatable {
    var listeningGranted = false
    var accessibilityGranted = false
    var tap: InputTapState = .stopped
    var receivedEvents = false
    var storage: InputStatisticsStore.WriteState?

    mutating func refresh(
        permissions: any InputPermissionProviding,
        listener: (any InputEventListening)?,
        enabled: Bool,
        paused: Bool,
        storage: InputStatisticsStore.WriteState?
    ) {
        listeningGranted = permissions.canListen()
        accessibilityGranted = permissions.canUseAccessibility()
        if PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: enabled, paused: paused, permissionGranted: listeningGranted
        ) {
            if listener?.tapState != .listening { listener?.start() }
        } else {
            listener?.stop()
        }
        tap = listener?.tapState ?? .stopped
        receivedEvents = listener?.receivedEvents ?? false
        self.storage = storage
    }
}
