import Foundation

/// iOS/iPadOS CloudKit sync only on explicit app foreground activity. This
/// policy NEVER reads UIPasteboard or starts a background observation session.
public enum ClipboardCloudForegroundSyncPolicy {
    public static let minimumIntervalSeconds: TimeInterval = 300

    public static func mayAttempt(
        cloudEnabled: Bool, foregroundEnabled: Bool,
        containerConfigured: Bool, busy: Bool,
        lastAttempt: Date?, now: Date
    ) -> Bool {
        guard cloudEnabled, foregroundEnabled, containerConfigured, !busy else {
            return false
        }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= minimumIntervalSeconds
    }
}
