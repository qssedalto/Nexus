import SwiftUI

extension DropFeedback {
    var symbol: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .observation: "doc.on.clipboard"
        }
    }

    var color: Color {
        switch kind {
        case .success: .green
        case .failure: .red
        case .observation: .primary
        }
    }
}

struct FeedbackPopoverView: View {
    static let contentSize = CGSize(width: 220, height: 52)
    let feedback: DropFeedback

    var body: some View {
        StatusPopoverContentView(
            systemImage: feedback.symbol,
            iconColor: feedback.color,
            title: feedback.message,
            detail: feedback.detail
        )
    }
}

struct DropReadyPopoverView: View {
    var body: some View {
        StatusPopoverContentView(
            systemImage: "arrow.down.circle.fill",
            iconColor: .accentColor,
            title: localized("Ready to drop"),
            detail: localized("Release to copy path")
        )
    }
}

private struct StatusPopoverContentView: View {
    let systemImage: String
    let iconColor: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom("Avenir Next", size: 13).weight(.semibold))
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(width: FeedbackPopoverView.contentSize.width, height: FeedbackPopoverView.contentSize.height)
        .background(.regularMaterial)
    }
}
