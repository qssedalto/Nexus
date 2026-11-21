import AppKit
import SwiftUI

struct SettingsView<Updater: UpdaterControlling>: View {
    @ObservedObject var appState: AppState
    let buildInfo: AppBuildInfo
    @ObservedObject var updater: Updater
    @ObservedObject private var clipboardMonitor = ClipboardMonitor.shared
    @ObservedObject private var clipboardHotkey = ClipboardHotkeyController.shared
    @AppStorage("nexusMonitorPasteRequests") private var pasteRequestMonitoring = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label(localized("General"), systemImage: "gearshape")
                }

            FinderSettingsView(appState: appState)
                .tabItem {
                    Label(localized("Finder"), systemImage: "folder")
                }

            SystemServicesView(appState: appState)
                .tabItem { Label(localized("System Services"), systemImage: "square.stack") }

            OperationTimelineView(appState: appState)
                .tabItem { Label(localized("Timeline"), systemImage: "clock") }

            InputStatisticsView()
                .tabItem { Label(localized("Keyboard and Mouse"), systemImage: "keyboard") }

            NetworkSyncView()
                .tabItem { Label(localized("Network sync"), systemImage: "arrow.triangle.2.circlepath") }

            AboutView(
                buildInfo: buildInfo,
                canCheckForUpdates: updater.canCheckForUpdates,
                onCheckForUpdates: updater.checkForUpdates
            )
            .tabItem {
                Label(localized("About"), systemImage: "info.circle")
            }
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 340, idealHeight: 340)
        .font(.custom("Avenir Next", size: 13, relativeTo: .body))
        .onAppear {
            appState.refreshLaunchAtLoginStatus()
            appState.refreshFinderExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshLaunchAtLoginStatus()
            appState.refreshFinderExtensionStatus()
        }
    }

    private var generalSettings: some View {
        Form {
            Section(localized("Startup")) {
                Toggle(localized("Launch Nexus at login"), isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { appState.setLaunchAtLoginEnabled($0) }
                ))

                Text(localized("Keeps Nexus ready in the menu bar after you sign in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(localized("Copy history")) {
                Toggle(localized("Monitor file copies from the clipboard"), isOn: $clipboardMonitor.enabled)
                Toggle(localized("Record clipboard text (opt-in)"), isOn: $clipboardMonitor.textEnabled)
                Toggle(localized("Pause clipboard history collection"), isOn: $clipboardMonitor.paused)
                Toggle(localized("Observe Command+V paste requests (opt-in)"), isOn: $pasteRequestMonitoring)
                Text(localized("Only a shortcut request and event timestamp are saved. This cannot verify a successful paste, does not inspect the destination, and requires input-monitoring permission."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Text history can include private information. Enable only when you want Nexus to store copied text locally."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Records detected clipboard changes, not confirmed file transfers or paste completion."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(localized("Excluded foreground app bundle IDs (comma separated)"),
                          text: $clipboardMonitor.excludedApps)
                Text(localized("Excluding the foreground app is best-effort; pasteboards do not reliably identify the source app. Pause history for sensitive sessions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("Local history retention")) {
                Picker(localized("Delete unpinned history after"), selection: $clipboardMonitor.retentionDays) {
                    Text(localized("Never")).tag(0)
                    Text("7 d").tag(7)
                    Text("30 d").tag(30)
                    Text("90 d").tag(90)
                    Text("365 d").tag(365)
                }
                Picker(localized("Maximum unpinned history records"), selection: $clipboardMonitor.maximumHistoryRecords) {
                    Text(localized("Unlimited")).tag(0)
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("5000").tag(5000)
                }
                Button(localized("Apply local cleanup now")) {
                    clipboardMonitor.cleanupNow()
                }
                Text(clipboardMonitor.cleanupStatus).font(.caption).foregroundStyle(.secondary)
                Text(localized("Pinned records are preserved. Local deletion does not automatically erase an earlier cloud upload."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("Clipboard shortcut")) {
                Picker(localized("Show or hide clipboard shelf"), selection: Binding(
                    get: { clipboardHotkey.selected },
                    set: { _ = clipboardHotkey.setPreset($0) }
                )) {
                    ForEach(ClipboardHotkeyController.Preset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Text(localized("Shortcuts are off by default. If the shortcut is occupied, the previous setting is kept."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(clipboardHotkey.status).font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("Copy feedback")) {
                Picker(localized("Show feedback for"), selection: Binding(
                    get: { appState.feedbackDuration },
                    set: { appState.setFeedbackDuration($0) }
                )) {
                    Text(localized("Off")).tag(0.0)
                    Text("0.5 s").tag(0.5)
                    Text("0.9 s").tag(0.9)
                    Text("1.5 s").tag(1.5)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}
