import Foundation

/// Clipboard observation and expiry are independent privacy controls.
/// Pausing capture must not preserve previously saved history indefinitely.
public enum ClipboardRetentionActivityPolicy {
    public static func shouldObserve(
        paused: Bool, files: Bool, text: Bool, images: Bool
    ) -> Bool {
        !paused && (files || text || images)
    }

    public static func shouldRunCleanup(
        retentionDays: Int, maximumHistoryRecords: Int
    ) -> Bool {
        retentionDays > 0 || maximumHistoryRecords > 0
    }
}
