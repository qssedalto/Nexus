import AppKit
import ApplicationServices
import SwiftUI
import SlashgrabCore

/// One home for all observation, retention and network-consent settings.
@MainActor
struct PrivacySettingsView: View {
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @ObservedObject private var statistics = InputStatisticsController.shared
    @ObservedObject private var sync = NetworkSyncController.shared
    @AppStorage("nexusMonitorPasteRequests") private var pasteObservation = false
    @AppStorage("nexusClipboardFileThumbnailPreviews") private var allowFilePreviews = false

    var body: some View {
        Form {
            Section(localized("Input monitoring and permissions")) {
                HStack {
                    Label(
                        localized(statistics.permissionGranted ? "Input permission granted" : "Input permission required"),
                        systemImage: statistics.permissionGranted ? "checkmark.shield" : "lock.shield"
                    )
                    Spacer()
                    if !statistics.permissionGranted {
                        Button(localized("Grant input permission")) {
                            statistics.requestPermission()
                        }
                    }
                }
                Toggle(localized("Pause statistics"), isOn: $statistics.paused)
                HStack {
                    Text(localized("Accessibility permission for quick paste"))
                    Spacer()
                    Text(localized(AXIsProcessTrusted() ? "Granted" : "Not granted"))
                        .foregroundStyle(.secondary)
                    Button(localized("Request access…")) {
                        _ = AXIsProcessTrustedWithOptions([
                            "AXTrustedCheckOptionPrompt": true
                        ] as CFDictionary)
                    }
                }
                Text(localized("Nexus never reads typed text, password fields, or browser pages. Statistical key categories are stored locally unless you explicitly configure network sync."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Clipboard history privacy")) {
                Toggle(localized("Monitor file copies from the clipboard"), isOn: $clipboard.enabled)
                Toggle(localized("Record clipboard text (opt-in)"), isOn: $clipboard.textEnabled)
                Picker(localized("Identical plain-text copies"),
                       selection: $clipboard.textDuplicatePolicy) {
                    ForEach(ClipboardTextDuplicatePolicy.allCases, id: \.rawValue) { policy in
                        Text(localized(policy.title)).tag(policy)
                    }
                }
                .disabled(!clipboard.textEnabled)
                Text(localized("Default keeps every copy. Optional consolidation only refreshes the most recent identical plain-text entry within 10 minutes; files, images and formatted text break the sequence."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Save safe RTF typography (opt-in)"),
                       isOn: $clipboard.richTextEnabled)
                    .disabled(!clipboard.textEnabled)
                Text(localized("RTF and safe HTML formatting retain only bold, italic and underline flags. Unsupported HTML, attachments, remote resources, fonts and original markup are never saved."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Save copied image pixels (opt-in, 8 MB maximum)"),
                       isOn: $clipboard.imageEnabled)
                Toggle(localized("Preview local copied files using Quick Look (opt-in)"),
                       isOn: $allowFilePreviews)
                Text(localized("File previews read only local supported files up to 24 MB. Cloud-only files and File Provider folders show an icon, without a requested download."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Image capture is off by default. Stored image bytes stay local, share duplicate storage, and are removed when the last history reference is deleted. Oversized or unreadable images retain metadata only."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Pause clipboard history collection"), isOn: $clipboard.paused)
                Toggle(localized("Observe Command+V paste requests (opt-in)"), isOn: $pasteObservation)
                Text(localized("Only a shortcut request and event timestamp are saved. This cannot verify a successful paste, does not inspect the destination, and requires input-monitoring permission."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Records detected clipboard changes, not confirmed file transfers or paste completion."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(
                    localized("Excluded foreground app bundle IDs (comma separated)"),
                    text: $clipboard.excludedApps
                )
                Text(localized("Source app exclusions are best-effort. Pasteboards cannot reliably identify the originating app, so pause monitoring during sensitive sessions."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Local history retention")) {
                Picker(localized("Delete unpinned history after"), selection: $clipboard.retentionDays) {
                    Text(localized("Never")).tag(0)
                    Text("7 d").tag(7)
                    Text("30 d").tag(30)
                    Text("90 d").tag(90)
                    Text("365 d").tag(365)
                }
                Picker(localized("Maximum unpinned history records"), selection: $clipboard.maximumHistoryRecords) {
                    Text(localized("Unlimited")).tag(0)
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("5000").tag(5000)
                }
                Button(localized("Apply local cleanup now")) { clipboard.cleanupNow() }
                Text(clipboard.cleanupStatus).font(.caption).foregroundStyle(.secondary)
                Text(localized("Pinned records and permanent collections survive automated cleanup. Deleting local history does not erase previous cloud uploads."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(localized("Network consent")) {
                Toggle(localized("Automatic sync"), isOn: $sync.automatic)
                Toggle(localized("Precise non-text events"), isOn: $sync.preciseEvents)
                Toggle(localized("Allow operation metadata sync"), isOn: $sync.operationSyncEnabled)
                Toggle(localized("Include full source and target paths"), isOn: $sync.operationSyncPaths)
                    .disabled(!sync.operationSyncEnabled)
                Toggle(localized("Include copied text contents"), isOn: $sync.operationSyncText)
                    .disabled(!sync.operationSyncEnabled)
                Text(localized("Operation uploads are off by default. Full paths and clipboard contents require separate consent even after metadata sync is enabled. Server-side deletion is controlled from Network sync."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}
