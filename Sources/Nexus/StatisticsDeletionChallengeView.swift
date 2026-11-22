import SwiftUI
import NexusCore

/// A modal challenge that makes progress visible without opening a thousand
/// independent system alerts. Closing or canceling never deletes any data.
struct StatisticsDeletionChallengeView: View {
    let deleteAllRequested: Bool
    let onCancel: () -> Void
    let onConfirmed: () -> Void
    @State private var step = 1

    private var stage: Int { (step - 1) / 100 + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "hand.raised.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.orange)
                    .scaleEffect(step.isMultiple(of: 100) ? 1.12 : 1.0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Confirm deletion"))
                        .font(.title2.bold())
                    Text("\(localized("Confirmation stage")) \(stage)/10")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step)/\(StatisticsDeletionConfirmationPolicy.requiredSteps)")
                    .font(.title3.monospacedDigit().bold())
            }

            ProgressView(
                value: Double(step - 1),
                total: Double(StatisticsDeletionConfirmationPolicy.requiredSteps)
            )
            .tint(.orange)
            .accessibilityLabel(localized("Deletion confirmation progress"))

            Text(localized(StatisticsDeletionConfirmationPolicy.prompt(forStep: step)
                    ?? "Review the time range to be deleted."))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(localized(deleteAllRequested
                ? "This deletes every locally stored input statistic. Existing cloud backups and uploads are not deleted."
                : "This deletes statistics in the selected time range."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(localized("You may cancel at any point. No statistics are deleted until the final confirmation."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(localized("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive) {
                    if StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: step) {
                        onConfirmed()
                    } else if let next = StatisticsDeletionConfirmationPolicy.nextStep(
                        afterConfirmed: step
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) { step = next }
                    } else {
                        onCancel()
                    }
                } label: {
                    Text(localized("Confirm"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(26)
        .frame(width: 530)
        .interactiveDismissDisabled()
    }
}
