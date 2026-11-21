import Foundation

/// Explicit acknowledgement sequence for destructive local input statistics
/// deletion. Each step has a distinct prompt so repeated clicks require the
/// user to review the scope rather than dismiss ten identical alerts.
public enum StatisticsDeletionConfirmationPolicy {
    public static let requiredSteps = 10

    private static let prompts = [
        "Review the time range to be deleted.",
        "These statistics were recorded locally on this Mac.",
        "Deletion removes the selected local records permanently.",
        "Deleting local data does not remove existing cloud backups.",
        "Deleting local data does not erase previously uploaded server records.",
        "Pinned clipboard entries are separate from input statistics.",
        "A deleted statistical event cannot be restored without a separate backup.",
        "Verify that the selected range is correct before continuing.",
        "This is the ninth confirmation; you can still cancel safely.",
        "Final confirmation: permanently delete these local statistics."
    ]

    public static func prompt(forStep step: Int) -> String? {
        guard (1...requiredSteps).contains(step) else { return nil }
        return prompts[step - 1]
    }

    public static func nextStep(afterConfirmed step: Int) -> Int? {
        guard (1...requiredSteps).contains(step), step < requiredSteps else { return nil }
        return step + 1
    }

    public static func allowsDeletion(afterConfirmed step: Int) -> Bool {
        step == requiredSteps
    }
}
