import AppKit
import SwiftUI

private struct ServiceRecord: Identifiable, Sendable {
    let id: String
    let name: String
    let application: String
    let bundleID: String?
    let category: String?
    let inputTypes: [String]
    let shortcut: String?
}

@MainActor
private final class SystemServicesModel: ObservableObject {
    @Published private(set) var services: [ServiceRecord] = []
    @Published private(set) var scanning = false

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scanBundles()
            await MainActor.run {
                self.services = found
                self.scanning = false
            }
        }
    }

    nonisolated private static func scanBundles() -> [ServiceRecord] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), homeApplications]
        var records: [ServiceRecord] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in entries where app.pathExtension == "app" {
                guard let bundle = Bundle(url: app),
                      let definitions = bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] else { continue }
                let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? app.deletingPathExtension().lastPathComponent
                for (index, definition) in definitions.enumerated() {
                    let menu = definition["NSMenuItem"] as? [String: String]
                    let name = menu?["default"] ?? "Unknown service"
                    let sendTypes = (definition["NSSendFileTypes"] as? [String] ?? []) + (definition["NSSendTypes"] as? [String] ?? [])
                    let shortcut = (definition["NSKeyEquivalent"] as? [String: String])?["default"]
                    records.append(ServiceRecord(id: "\(app.path)#\(index)", name: name, application: appName, bundleID: bundle.bundleIdentifier, category: definition["NSServiceCategory"] as? String, inputTypes: sendTypes, shortcut: shortcut))
                }
            }
        }
        return records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct SystemServicesView: View {
    @StateObject private var model = SystemServicesModel()
    @State private var search = ""
    @State private var category = "All"

    private var categories: [String] {
        ["All"] + Array(Set(model.services.compactMap(\.category))).sorted()
    }

    private var displayed: [ServiceRecord] {
        model.services.filter { record in
            (category == "All" || record.category == category) &&
            (search.isEmpty || record.name.localizedCaseInsensitiveContains(search) || record.application.localizedCaseInsensitiveContains(search) || (record.bundleID?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField(localized("Search services"), text: $search)
                Picker(localized("Category"), selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Button(localized("Refresh")) { model.refresh() }
                Button(localized("Open macOS Services Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Services") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text(localized("Services found in installed application bundles. Activation and menu placement are determined by macOS."))
                .font(.caption).foregroundStyle(.secondary)
            List(displayed) { service in
                DisclosureGroup(service.name) {
                    LabeledContent(localized("Application"), value: service.application)
                    LabeledContent(localized("Bundle Identifier"), value: service.bundleID ?? localized("Unknown"))
                    LabeledContent(localized("Category"), value: service.category ?? localized("Unknown"))
                    LabeledContent(localized("Input types"), value: service.inputTypes.isEmpty ? localized("Unknown") : service.inputTypes.joined(separator: ", "))
                    LabeledContent(localized("Shortcut"), value: service.shortcut ?? localized("Unknown"))
                    LabeledContent(localized("Enabled"), value: localized("Unknown"))
                    LabeledContent(localized("Menu location"), value: localized("Unknown"))
                    LabeledContent(localized("Editable by Nexus"), value: localized("No"))
                }
            }
        }
        .padding()
        .onAppear { model.refresh() }
    }
}
