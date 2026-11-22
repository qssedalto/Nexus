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
        Group {
            if let appIcon, let displayName {
                HStack(spacing: 5) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text(displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .accessibilityLabel(displayName)
            }
        }
        .task(id: operation.sourceApplication) {
            appIcon = nil
            displayName = nil
            guard let bundleID = operation.sourceApplication,
                  let appURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID
                  ) else { return }
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            displayName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent
        }
    }
}
