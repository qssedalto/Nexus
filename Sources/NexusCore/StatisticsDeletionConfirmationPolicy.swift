import Foundation

/// A deliberately lengthy, cancelable deletion challenge requested by the user.
/// No step is skipped and a new confirmation session always starts at step one.
public enum StatisticsDeletionConfirmationPolicy {
    public static let requiredSteps = 1_000

    private static let prompts = [
        "Review the time range to be deleted.",
        "These statistics were recorded locally on this Mac.",
        "Deletion removes the selected local records permanently.",
        "Deleting local data does not remove existing cloud backups.",
        "Deleting local data does not erase previously uploaded server records.",
        "Pinned clipboard entries are separate from input statistics.",
        "A deleted statistical event cannot be restored without a separate backup.",
        "Verify that the selected range is correct before continuing.",
        "You can cancel now without deleting any statistics."
    ]

    public static func prompt(forStep step: Int) -> String? {
        guard (1...requiredSteps).contains(step) else { return nil }
        if step == requiredSteps {
            return "Final confirmation: permanently delete these local statistics."
        }
        return prompts[(step - 1) % prompts.count]
    }

    public static func nextStep(afterConfirmed step: Int) -> Int? {
        guard (1...requiredSteps).contains(step), step < requiredSteps else { return nil }
        return step + 1
    }

    public static func allowsDeletion(afterConfirmed step: Int) -> Bool {
        step == requiredSteps
    }
}
