import AppKit
import SwiftUI
import SlashgrabCore

struct SettingsView<Updater: UpdaterControlling>: View {
    @ObservedObject var appState: AppState
    let buildInfo: AppBuildInfo
    @ObservedObject var updater: Updater
    @ObservedObject private var clipboardHotkey = ClipboardHotkeyController.shared
    @State private var editingCustomShortcut = false
    @State private var customKey: ClipboardShortcutKey = .v
    @State private var customControl = true
    @State private var customOption = true
    @State private var customShift = false
    @State private var customCommand = false

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

            PrivacySettingsView()
                .tabItem { Label(localized("Privacy and Permissions"), systemImage: "hand.raised") }

            AboutView(
                buildInfo: buildInfo,
                canCheckForUpdates: updater.canCheckForUpdates,
                onCheckForUpdates: updater.checkForUpdates
            )
            .tabItem {
                Label(localized("About"), systemImage: "info.circle")
            }
        }
        .frame(minWidth: 650, idealWidth: 760, minHeight: 410, idealHeight: 510)
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
                HStack {
                    Button(localized("Configure custom shortcut…")) {
                        loadCustomShortcut()
                        editingCustomShortcut = true
                    }
                    if let current = clipboardHotkey.customShortcut {
                        Text(current.displayName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(localized("Custom shortcuts require two or more modifiers. Keys use physical keyboard positions; system conflicts are rejected without losing the previous shortcut."))
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
        .sheet(isPresented: $editingCustomShortcut) {
            customShortcutEditor
        }
    }

    private var customShortcutEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Custom clipboard shortcut"))
                .font(.headline)
            Picker(localized("Key"), selection: $customKey) {
                ForEach(ClipboardShortcutKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .frame(maxWidth: 260)
            HStack(spacing: 14) {
                Toggle("⌃ Control", isOn: $customControl)
                Toggle("⌥ Option", isOn: $customOption)
                Toggle("⇧ Shift", isOn: $customShift)
                Toggle("⌘ Command", isOn: $customCommand)
            }
            .toggleStyle(.checkbox)
            Text(localized("Choose at least two modifiers. If macOS already uses the combination, Nexus keeps the previous shortcut."))
                .font(.caption).foregroundStyle(.secondary)
            Text(clipboardHotkey.status)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(localized("Cancel")) { editingCustomShortcut = false }
                Button(localized("Apply shortcut")) {
                    var modifiers = Set<ClipboardShortcutModifier>()
                    if customControl { modifiers.insert(.control) }
                    if customOption { modifiers.insert(.option) }
                    if customShift { modifiers.insert(.shift) }
                    if customCommand { modifiers.insert(.command) }
                    let candidate = ClipboardShortcutSpecification(
                        key: customKey, modifiers: modifiers
                    )
                    if clipboardHotkey.setCustomShortcut(candidate) {
                        editingCustomShortcut = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 520)
    }

    private func loadCustomShortcut() {
        let candidate = clipboardHotkey.customShortcut ??
            ClipboardShortcutSpecification(key: .v, modifiers: [.control, .option])
        customKey = candidate.key
        customControl = candidate.modifiers.contains(.control)
        customOption = candidate.modifiers.contains(.option)
        customShift = candidate.modifiers.contains(.shift)
        customCommand = candidate.modifiers.contains(.command)
    }
}
