import Foundation

/// CloudKit scheduling is independent from local clipboard capture and is
/// intentionally opt-in. An existing signed-in Apple account alone never
/// triggers a background read or write.
public enum ClipboardCloudAutomaticSyncPolicy {
    public static let intervalSeconds: TimeInterval = 300

    public static func maySchedule(
        cloudEnabled: Bool, automaticEnabled: Bool, containerConfigured: Bool
    ) -> Bool {
        cloudEnabled && automaticEnabled && containerConfigured
    }

    public static func mayStartCycle(
        cloudEnabled: Bool, automaticEnabled: Bool,
        containerConfigured: Bool, busy: Bool
    ) -> Bool {
        maySchedule(
            cloudEnabled: cloudEnabled,
            automaticEnabled: automaticEnabled,
            containerConfigured: containerConfigured
        ) && !busy
    }
}
