import AppKit
import NexusCore
import SwiftUI

/// A best-effort visual cue, never a claim about the actual clipboard writer.
/// The foreground app at observation time may differ from the source app.
struct ClipboardSourceAppBadge: View {
    let operation: RecordedOperation
    @State private var appIcon: NSImage?
    @State private var displayName: String?

    var body: some View {
        HStack(spacing: 4) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app")
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .task(id: operation.sourceApplication) {
            appIcon = nil
            displayName = nil
            guard let bundleID = operation.sourceApplication,
                  let appURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID
                  ) else { return }
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            displayName = appURL.deletingPathExtension().lastPathComponent
        }
    }

    private var label: String {
        switch ClipboardSourceAttribution.classify(operation) {
        case .unknown:
            return localized("Source application unknown")
        case .observedForeground(let bundleID):
            return localized("Foreground app at copy detection (unverified): ")
                + (displayName ?? bundleID)
        case .reported(let bundleID):
            return localized("Reported source app: ") + (displayName ?? bundleID)
        }
    }
}
