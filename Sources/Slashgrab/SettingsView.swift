import AppKit
import SwiftUI

struct SettingsView<Updater: UpdaterControlling>: View {
    @ObservedObject var appState: AppState
    let buildInfo: AppBuildInfo
    @ObservedObject var updater: Updater
    @ObservedObject private var clipboardMonitor = ClipboardMonitor.shared

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

            SystemServicesView()
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
                Text(localized("Text history can include private information. Enable only when you want Nexus to store copied text locally."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Records detected clipboard changes, not confirmed file transfers or paste completion."))
                    .font(.caption).foregroundStyle(.secondary)
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
