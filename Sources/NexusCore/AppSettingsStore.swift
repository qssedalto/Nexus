import Foundation

public final class AppSettingsStore: @unchecked Sendable {
    private enum Key {
        static let historyEntries = "historyEntries"
        static let historyLimit = "historyLimit"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let useFinderSubmenu = "useFinderSubmenu"
        static let feedbackDuration = "nexusFeedbackDuration"
    }

    static let selectedFormatKey = "selectedPathFormat"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var selectedFormat: PathFormat {
        get {
            guard let rawValue = defaults.string(forKey: Self.selectedFormatKey),
                  let format = PathFormat(rawValue: rawValue) else {
                return .shellEscaped
            }
            return format
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectedFormatKey)
        }
    }

    public var historyLimit: Int {
        get {
            let value = defaults.integer(forKey: Key.historyLimit)
            return value > 0 ? value : 10
        }
        set {
            defaults.set(max(1, newValue), forKey: Key.historyLimit)
        }
    }

    /// Distinguish a genuinely new installation from an existing user who
    /// intentionally turned launch-at-login off. Do not override existing
    /// preferences during upgrades.
    public var hasStoredLaunchAtLoginPreference: Bool {
        defaults.object(forKey: Key.launchAtLoginEnabled) != nil
    }

    public var launchAtLoginEnabled: Bool {
        get {
            defaults.bool(forKey: Key.launchAtLoginEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLoginEnabled)
        }
    }

    public var useFinderSubmenu: Bool {
        get { defaults.bool(forKey: Key.useFinderSubmenu) }
        set { defaults.set(newValue, forKey: Key.useFinderSubmenu) }
    }

    public var feedbackDuration: Double {
        get {
            guard defaults.object(forKey: Key.feedbackDuration) != nil else { return 1.5 }
            return defaults.double(forKey: Key.feedbackDuration)
        }
        set { defaults.set(newValue, forKey: Key.feedbackDuration) }
    }

    public func loadHistory() -> PathHistory {
        PathHistory(entries: defaults.stringArray(forKey: Key.historyEntries) ?? [], limit: historyLimit)
    }

    public func saveHistory(_ history: PathHistory) {
        defaults.set(history.limit, forKey: Key.historyLimit)
        defaults.set(history.entries, forKey: Key.historyEntries)
    }

    public func addHistoryEntry(_ output: String) {
        var history = loadHistory()
        history.add(output)
        saveHistory(history)
    }
}
