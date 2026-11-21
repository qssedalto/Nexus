import AppKit
import Foundation
import SwiftUI

/// Explicit, reversible control for the *global* Finder Services submenu
/// threshold. This is NOT per-service control and never runs at app startup.
@MainActor
final class GlobalServicesMenuPreference: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case systemDefault
        case expand
        case submenu

        var id: String { rawValue }
        var label: String {
            switch self {
            case .systemDefault: return localized("Follow system default")
            case .expand: return localized("Expand all Services where possible")
            case .submenu: return localized("Group Services in submenu")
            }
        }
    }

    @Published private(set) var currentValue: Int?
    @Published private(set) var message: String?
    @Published private(set) var hasBackup = false

    private let preferencesKey = "NSServicesMinimumItemCountForContextSubmenu"
    private let backupKey = "nexusOriginalGlobalServicesSubmenuPreferenceV1"
    private let defaults = UserDefaults.standard

    init() { refresh() }

    var currentSummary: String {
        guard let currentValue else { return localized("System default (no override)") }
        return "\(localized("Global threshold")): \(currentValue)"
    }

    var currentMode: Mode {
        switch currentValue {
        case nil: return .systemDefault
        case 999: return .expand
        case 1: return .submenu
        default: return .systemDefault
        }
    }

    func refresh() {
        hasBackup = defaults.data(forKey: backupKey) != nil
        do {
            currentValue = try readGlobalValue()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func apply(_ mode: Mode) -> Bool {
        do {
            // Create the exact original-value backup before the first write.
            // A value of nil is different from an explicit numeric override.
            let before = try readGlobalValue()
            if defaults.data(forKey: backupKey) == nil {
                let backup: [String: Any] = [
                    "wasSet": before != nil,
                    "intValue": before ?? 0,
                ]
                let data = try PropertyListSerialization.data(
                    fromPropertyList: backup, format: .binary, options: 0
                )
                defaults.set(data, forKey: backupKey)
            }
            switch mode {
            case .systemDefault:
                if before != nil {
                    _ = try executeDefaults(["delete", "-g", preferencesKey])
                }
            case .expand:
                _ = try executeDefaults(["write", "-g", preferencesKey, "-int", "999"])
            case .submenu:
                _ = try executeDefaults(["write", "-g", preferencesKey, "-int", "1"])
            }
            refresh()
            message = localized("Global Services setting updated; reopen the Finder menu.")
            return true
        } catch {
            refresh()
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func restoreOriginal() -> Bool {
        do {
            guard let data = defaults.data(forKey: backupKey),
                  let object = try PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any],
                  let wasSet = object["wasSet"] as? Bool,
                  let intValue = object["intValue"] as? Int else {
                message = localized("No saved original setting found")
                return false
            }
            let currentlySet = try readGlobalValue()
            if wasSet {
                _ = try executeDefaults(["write", "-g", preferencesKey, "-int", String(intValue)])
            } else if currentlySet != nil {
                _ = try executeDefaults(["delete", "-g", preferencesKey])
            }
            // Never erase the only snapshot until the restore succeeded.
            defaults.removeObject(forKey: backupKey)
            refresh()
            message = localized("Original global Services setting restored")
            return true
        } catch {
            refresh()
            message = error.localizedDescription
            return false
        }
    }

    /// Get the actual global-domain value instead of the app's UserDefaults
    /// merged fallback, which could mask whether the key was originally unset.
    private func readGlobalValue() throws -> Int? {
        let data = try executeDefaults(["export", "NSGlobalDomain", "-"])
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw PreferenceError.invalidGlobalDomain
        }
        guard let value = plist[preferencesKey] else { return nil }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) != "d",
              String(cString: number.objCType) != "f" else {
            // Do not guess the user's prior type and lose data when restoring.
            throw PreferenceError.unsupportedExistingType
        }
        return number.intValue
    }

    private func executeDefaults(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PreferenceError.defaultsCommandFailed
        }
        return data
    }

    private enum PreferenceError: LocalizedError {
        case invalidGlobalDomain
        case unsupportedExistingType
        case defaultsCommandFailed

        var errorDescription: String? {
            switch self {
            case .invalidGlobalDomain:
                return localized("Cannot inspect global Services preferences")
            case .unsupportedExistingType:
                return localized("Existing preference type is not an integer; no changes were made")
            case .defaultsCommandFailed:
                return localized("Could not change global Services preferences; no settings were deleted")
            }
        }
    }
}

@MainActor
struct GlobalServicesMenuControls: View {
    @StateObject private var controller = GlobalServicesMenuPreference()
    @State private var proposed: GlobalServicesMenuPreference.Mode = .systemDefault
    @State private var showingApplyConfirmation = false
    @State private var showingRestoreConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("This setting changes the Services submenu for every app, not only Nexus."))
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent(localized("Current global setting"), value: controller.currentSummary)
            Picker(localized("Services menu layout"), selection: $proposed) {
                ForEach(GlobalServicesMenuPreference.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            HStack {
                Button(localized("Apply system-wide…")) {
                    showingApplyConfirmation = true
                }
                .alert(localized("Change Services menus for all apps?"),
                       isPresented: $showingApplyConfirmation) {
                    Button(localized("Cancel"), role: .cancel) {}
                    Button(localized("Apply system-wide")) { _ = controller.apply(proposed) }
                } message: {
                    Text(localized("This global setting may change where other apps' Services appear. Finder may need to reopen its context menu."))
                }

                Button(localized("Restore previous global value…")) {
                    showingRestoreConfirmation = true
                }
                .disabled(!controller.hasBackup)
                .alert(localized("Restore the saved global Services value?"),
                       isPresented: $showingRestoreConfirmation) {
                    Button(localized("Cancel"), role: .cancel) {}
                    Button(localized("Restore original")) { _ = controller.restoreOriginal() }
                } message: {
                    Text(localized("Restore the exact integer value (or unset state) saved before Nexus first changed this preference."))
                }

                Button(localized("Refresh")) { controller.refresh() }
            }
            .controlSize(.small)

            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            controller.refresh()
            proposed = controller.currentMode
        }
    }
}
