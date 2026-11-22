import AppKit
import SwiftUI
import NexusCore

@MainActor
private final class SystemServicesModel: ObservableObject {
    @Published private(set) var services: [NativeServiceDefinition] = []
    @Published private(set) var scanning = false

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result = await Task.detached(priority: .utility) {
                NativeServicesCatalog.scan()
            }.value
            services = result
            scanning = false
        }
    }
}

struct SystemServicesView: View {
    @ObservedObject var appState: AppState
    @StateObject private var model = SystemServicesModel()
    @State private var search = ""
    @State private var category = "All"
    @State private var showGlobalLayout = false
    @State private var showOwnControls = true
    @State private var onlyOwnServices = false

    private var ownServices: [NativeServiceDefinition] {
        model.services.filter { $0.bundleID == Bundle.main.bundleIdentifier }
    }

    private var categories: [String] {
        ["All"] + Array(Set(model.services.compactMap(\.category))).sorted()
    }

    private var displayed: [NativeServiceDefinition] {
        model.services.filter { record in
            (!onlyOwnServices || record.bundleID == Bundle.main.bundleIdentifier) &&
            (category == "All" || record.category == category) &&
            (search.isEmpty ||
             record.name.localizedCaseInsensitiveContains(search) ||
             record.application.localizedCaseInsensitiveContains(search) ||
             (record.bundleID?.localizedCaseInsensitiveContains(search) ?? false) ||
             record.inputTypes.contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(localized("Search services"), text: $search)
                Picker(localized("Category"), selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Button(localized("Refresh")) { model.refresh() }
                    .disabled(model.scanning)
                if model.scanning { ProgressView().controlSize(.small) }
            }

            Text(localized("This is a read-only catalog of Services declared by installed apps and workflows. macOS alone determines effective activation and menu placement."))
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup(localized("Nexus copy-path service"), isExpanded: $showOwnControls) {
                if FinderExtensionController.embeddedExtensionURL != nil {
                    HStack {
                        Text(localized("Finder Sync copy command"))
                        Spacer()
                        Text(localized(appState.finderExtensionEnabled ? "Enabled" : "Disabled"))
                            .foregroundStyle(appState.finderExtensionEnabled ? .green : .secondary)
                    }
                    Picker(localized("Finder copy menu position"), selection: Binding(
                        get: { appState.useFinderSubmenu },
                        set: { appState.setUseFinderSubmenu($0) }
                    )) {
                        Text(localized("Direct context menu")).tag(false)
                        Text(localized("Nexus submenu")).tag(true)
                    }
                    .disabled(!appState.finderExtensionEnabled)
                    Button(localized("Manage Finder extension in macOS Settings…")) {
                        appState.showFinderExtensionSettings()
                    }
                } else {
                    Text(localized("Finder Sync is not bundled with this configuration"))
                        .foregroundStyle(.secondary)
                }

                if ownServices.isEmpty {
                    Text(localized("This build has no additional NSServices entry, preventing duplicate copy-path menus. The isolated ServicesPrototype build has a single native service instead of a Finder Sync copy menu."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(ownServices) { service in
                        Label(service.name, systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    Button(localized("Manage native Services in macOS Settings…")) {
                        openServicesSettings()
                    }
                }
                Text(localized("Native Services titles and per-item menu levels are part of macOS registration and cannot be changed live through a supported public API."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            DisclosureGroup(localized("Global Services menu layout"), isExpanded: $showGlobalLayout) {
                GlobalServicesMenuControls()
            }
            .padding(.horizontal, 4)

            HStack {
                Toggle(localized("Show only Nexus"), isOn: $onlyOwnServices)
                Spacer()
                Text("\(displayed.count) \(localized("declared services"))")
                    .foregroundStyle(.secondary).font(.caption)
                Button(localized("Open macOS Services Settings")) {
                    openServicesSettings()
                }
            }

            List(displayed) { service in
                DisclosureGroup {
                    LabeledContent(localized("Application"), value: service.application)
                    LabeledContent(localized("Bundle Identifier"), value: service.bundleID ?? localized("Unknown"))
                    LabeledContent(localized("Category"), value: service.category ?? localized("Unknown"))
                    LabeledContent(localized("Input types"), value: service.inputTypes.isEmpty
                        ? localized("Unknown")
                        : service.inputTypes.joined(separator: ", "))
                    LabeledContent(localized("Declared shortcut"), value: service.defaultShortcut ?? localized("Unknown"))
                    LabeledContent(localized("Enabled"), value: localized("Unknown"))
                    LabeledContent(localized("Menu location"), value: localized("Unknown"))
                    LabeledContent(localized("Editable by Nexus"), value: localized("No"))
                    Text(service.bundlePath).font(.caption2).textSelection(.enabled)
                    HStack {
                        Button(localized("Show application in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: service.bundlePath)
                            ])
                        }
                        Button(localized("Change service settings in macOS…")) {
                            openServicesSettings()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(service.name).fontWeight(.medium)
                        Spacer()
                        Text(service.application)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
        .onAppear {
            model.refresh()
            appState.refreshFinderExtensionStatus()
        }
    }

    private func openServicesSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Services") else { return }
        NSWorkspace.shared.open(url)
    }
}
