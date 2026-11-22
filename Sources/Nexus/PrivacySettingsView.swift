import AppKit
import ApplicationServices
import SwiftUI
import NexusCore

/// One home for all observation, retention and network-consent settings.
@MainActor
struct PrivacySettingsView: View {
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @ObservedObject private var statistics = InputStatisticsController.shared
    @ObservedObject private var sync = NetworkSyncController.shared
    @AppStorage("nexusMonitorPasteRequests") private var pasteObservation = false
    @AppStorage("nexusClipboardFileThumbnailPreviews") private var allowFilePreviews = false
    @AppStorage("nexusClipboardRemoteTitlesEnabled") private var allowRemoteTitles = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var fullTextEnabled = false
    @State private var fullTextBusy = false
    @State private var fullTextStatus = ""

    private func configureFullTextIndex(_ enabled: Bool) {
        guard !fullTextBusy else { return }
        fullTextBusy = true
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (Bool, String) in
                guard let store = OperationStore.shared() else {
                    return (false, "Local history database unavailable")
                }
                do {
                    try store.configureFullTextIndex(enabled: enabled)
                    return (try store.fullTextIndexEnabled(),
                            enabled ? "Search index ready" : "Search index removed")
                } catch {
                    return ((try? store.fullTextIndexEnabled()) ?? false,
                            "Search index unavailable: " + error.localizedDescription)
                }
            }.value
            fullTextEnabled = outcome.0
            fullTextStatus = outcome.1
            fullTextBusy = false
        }
    }

    var body: some View {
        Form {
            Section(localized("Input monitoring and permissions")) {
                HStack {
                    Label(
                        localized(statistics.permissionGranted
                            ? "Input monitoring: granted" : "Input monitoring: not granted"),
                        systemImage: statistics.permissionGranted
                            ? "checkmark.shield.fill" : "lock.shield"
                    )
                    Spacer()
                    if !statistics.permissionGranted {
                        Button(localized("Grant permission…")) {
                            statistics.requestPermission()
                        }
                    }
                }
                if !statistics.permissionGranted {
                    Text(localized("For keyboard and mouse counts, enable Nexus Drive in System Settings > Privacy & Security > Input Monitoring."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(localized("Open Input Monitoring settings")) {
                        statistics.openInputMonitoringSettings()
                    }
                }
                Toggle(localized("Enable keyboard and mouse statistics"),
                       isOn: $statistics.enabled)
                Toggle(localized("Pause statistics"), isOn: $statistics.paused)
                    .disabled(!statistics.enabled)

                Divider()

                HStack {
                    Label(localized("Quick paste (Accessibility)"),
                          systemImage: accessibilityGranted
                            ? "checkmark.shield.fill" : "hand.raised")
                    Spacer()
                    Text(localized(accessibilityGranted
                        ? "Granted" : "Not granted"))
                        .foregroundColor(accessibilityGranted ? .green : .secondary)
                    if !accessibilityGranted {
                        Button(localized("Grant permission…")) {
                            accessibilityGranted = AXIsProcessTrustedWithOptions([
                                "AXTrustedCheckOptionPrompt": true
                            ] as CFDictionary)
                            if !accessibilityGranted,
                               let url = URL(string:
                                   "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Text(localized("Accessibility permission is only needed for quick paste. It is separate from Input Monitoring."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !statistics.permissionGranted || !accessibilityGranted {
                    Button(localized("Restart Nexus Drive to apply permissions")) {
                        NexusAppRelauncher.restart()
                    }
                    .help(localized("Restarts this exact application automatically. Your saved history is preserved."))
                } else {
                    Label(localized("Permissions are active"),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if !statistics.dataStatus.isEmpty,
                   statistics.dataStatus != localized("Statistics query complete") {
                    Text(statistics.dataStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(localized("Keyboard and mouse counts stay on this Mac unless you separately enable server uploads."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(localized("Clipboard history privacy")) {
                if !clipboard.storageAvailable {
                    Label(localized("Local clipboard storage could not be opened. Restart Nexus Drive after rebuilding the app."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if !clipboard.enabled && !clipboard.textEnabled && !clipboard.imageEnabled {
                    Text(localized("No clipboard types are selected. Enable Record clipboard text, file copying, or images below to begin collecting new entries."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(localized("Enable clipboard history monitoring"), isOn: $clipboard.historyEnabled)
                Toggle(localized("Monitor file copies from the clipboard"), isOn: $clipboard.enabled)
                    .disabled(!clipboard.historyEnabled)
                Toggle(localized("Record clipboard text (opt-in)"), isOn: $clipboard.textEnabled)
                    .disabled(!clipboard.historyEnabled)
                Picker(localized("Identical plain-text copies"),
                       selection: $clipboard.textDuplicatePolicy) {
                    ForEach(ClipboardTextDuplicatePolicy.allCases, id: \.rawValue) { policy in
                        Text(localized(policy.title)).tag(policy)
                    }
                }
                .disabled(!clipboard.historyEnabled || !clipboard.textEnabled)
                Text(localized("Default keeps every copy. Optional consolidation only refreshes the most recent identical plain-text entry within 10 minutes; files, images and formatted text break the sequence."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Save safe RTF typography (opt-in)"),
                       isOn: $clipboard.richTextEnabled)
                    .disabled(!clipboard.historyEnabled || !clipboard.textEnabled)
                Text(localized("RTF and safe HTML formatting retain only bold, italic and underline flags. Unsupported HTML, attachments, remote resources, fonts and original markup are never saved."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Save clipboard-provided link titles (opt-in)"),
                       isOn: $clipboard.linkTitleEnabled)
                    .disabled(!clipboard.historyEnabled || !clipboard.textEnabled)
                Text(localized("Clipboard-provided titles are saved locally when permitted, without network activity."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Allow explicit website title lookup (HTTPS only)"),
                       isOn: $allowRemoteTitles)
                    .disabled(!clipboard.historyEnabled || !clipboard.textEnabled)
                Text(localized("Off by default. After enabling, right-click a link card and choose Fetch website title once. This contacts that public website and reveals the selected URL; query parameters, URL credentials, local hosts and redirects are refused. No automatic requests."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Save copied image pixels (opt-in, 8 MB maximum)"),
                       isOn: $clipboard.imageEnabled)
                    .disabled(!clipboard.historyEnabled)
                Toggle(localized("Preview local copied files using Quick Look (opt-in)"),
                       isOn: $allowFilePreviews)
                Text(localized("File previews read only local supported files up to 24 MB. Cloud-only files and File Provider folders show an icon, without a requested download."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Image capture is off by default. Stored image bytes stay local, share duplicate storage, and are removed when the last history reference is deleted. Oversized or unreadable images retain metadata only."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(localized("Pause clipboard history collection"), isOn: $clipboard.paused)
                    .disabled(!clipboard.historyEnabled)
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

            Section(localized("Local full-text indexing")) {
                Toggle(localized("Maintain on-device clipboard search index (opt-in)"),
                       isOn: Binding(
                        get: { fullTextEnabled },
                        set: { configureFullTextIndex($0) }
                       ))
                    .disabled(fullTextBusy)
                if fullTextBusy { ProgressView().controlSize(.small) }
                Text(localized("Optional FTS5 indexing speeds up searches of three or more characters, including CJK text. Short terms and punctuation use the original exact search. Disabling the index removes its extra local plaintext copy without deleting clipboard history."))
                    .font(.caption).foregroundStyle(.secondary)
                if !fullTextStatus.isEmpty {
                    Text(fullTextStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(localized("Network consent")) {
                Toggle(localized("Allow statistics upload to configured server"), isOn: $sync.statisticsUploadEnabled)
                Toggle(localized("Automatic sync"), isOn: $sync.automatic)
                    .disabled(!sync.hasToken || !sync.statisticsUploadEnabled)
                Toggle(localized("Precise non-text events"), isOn: $sync.preciseEvents)
                    .disabled(!sync.statisticsUploadEnabled)
                Toggle(localized("Allow operation metadata sync"), isOn: $sync.operationSyncEnabled)
                Toggle(localized("Include full source and target paths"), isOn: $sync.operationSyncPaths)
                    .disabled(!sync.operationSyncEnabled)
                Toggle(localized("Include copied text contents"), isOn: $sync.operationSyncText)
                    .disabled(!sync.operationSyncEnabled)
                Text(localized("Statistical uploads remain off until you enable their independent switch; disabling it stops scheduled and manual statistics uploads without deleting local records."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Operation uploads are off by default. Full paths and clipboard contents require separate consent even after metadata sync is enabled. Server-side deletion is controlled from Network sync."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            statistics.refreshPermissionStatus()
            accessibilityGranted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            statistics.refreshPermissionStatus()
            accessibilityGranted = AXIsProcessTrusted()
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
        .onAppear {
            if let store = OperationStore.shared() {
                fullTextEnabled = (try? store.fullTextIndexEnabled()) ?? false
            }
        }
    }
}
