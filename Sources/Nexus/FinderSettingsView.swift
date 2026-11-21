import AppKit
import SwiftUI

struct FinderSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var installedExtensions: [InstalledFinderExtension] = []
    @State private var isWorking = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Nexus") {
                if FinderExtensionController.embeddedExtensionURL != nil {
                    extensionSettings
                }
            }

            installedExtensionsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    @ViewBuilder
    private var extensionSettings: some View {
        Toggle(localized("Put the extension’s copy command in a submenu"), isOn: Binding(
            get: { appState.useFinderSubmenu },
            set: { appState.setUseFinderSubmenu($0) }
        ))
        .disabled(!appState.finderExtensionEnabled)
        Text(localized("On shows the command under Nexus. Off shows it directly in the shortcut menu. Reopen the menu after changing this setting."))
            .font(.caption)
            .foregroundStyle(.secondary)

        LabeledContent(localized("Nexus Finder extension")) {
            Label(
                localized(appState.finderExtensionEnabled ? "Enabled" : "Disabled"),
                systemImage: appState.finderExtensionEnabled ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(appState.finderExtensionEnabled ? .green : .secondary)
        }

        Button(localized("Open Finder Extension Settings…"), action: openSystemSettings)
            .disabled(isWorking)
        Text(localized("The extension comes with Nexus. Open System Settings to turn it on."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var installedExtensionsSection: some View {
        Section(localized("Installed Finder Extensions")) {
            HStack {
                Button(localized("Refresh"), action: refresh)
                    .disabled(isWorking)
                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if hasLoaded && installedExtensions.isEmpty {
                Text(localized("No registered Finder extensions were found."))
                    .foregroundStyle(.secondary)
            }

            ForEach(installedExtensions) { entry in
                LabeledContent {
                    Menu(electionTitle(for: entry)) {
                        Button(localized("Enable")) { setEnabled(true, for: entry) }
                            .disabled(entry.election == .enabled)
                        Button(localized("Disable")) { setEnabled(false, for: entry) }
                            .disabled(entry.election == .disabled)
                    }
                    .accessibilityLabel(entry.name)
                    .fixedSize()
                    .disabled(isWorking)
                } label: {
                    Text(entry.name)
                    Text(entry.id)
                }
            }
        }
    }

    private func electionTitle(for entry: InstalledFinderExtension) -> String {
        switch entry.election {
        case .enabled: localized("Enabled")
        case .disabled: localized("Disabled")
        case .systemDefault: localized("System Default")
        }
    }

    private func refresh() {
        updateExtensions(error: localized("Couldn’t read Finder extensions.")) {
            try FinderExtensionRegistry.installedExtensions()
        }
    }

    private func setEnabled(_ enabled: Bool, for entry: InstalledFinderExtension) {
        updateExtensions(error: localized("Couldn’t change the Finder extension’s status. Use System Settings to try again.")) {
            try FinderExtensionRegistry.setEnabled(enabled, for: entry.id)
        }
    }

    private func updateExtensions(
        error message: String,
        using operation: @escaping @Sendable () throws -> [InstalledFinderExtension]
    ) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                installedExtensions = try await Task.detached(priority: .userInitiated, operation: operation).value
                hasLoaded = true
            } catch {
                errorMessage = message
            }
            appState.refreshFinderExtensionStatus()
        }
    }

    private func openSystemSettings() {
        guard !isWorking else { return }
        guard let url = FinderExtensionController.embeddedExtensionURL,
              !appState.finderExtensionEnabled else {
            appState.showFinderExtensionSettings()
            return
        }

        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FinderExtensionRegistry.registerEmbeddedExtensionIfNeeded(at: url)
                }.value
            } catch {
                errorMessage = localized("Couldn’t register the Nexus extension.")
            }
            appState.showFinderExtensionSettings()
        }
    }
}
