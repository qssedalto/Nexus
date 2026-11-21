import Foundation
import SQLite3

public enum SharedSettings {
    public static let appGroupIdentifierInfoKey = "NexusAppGroupIdentifier"
    public static let finderCopyNotification = Notification.Name("com.qssedalto.nexus.finderCopyCompleted")

    /// Preserves settings and SQLite history when moving to the Nexus bundle and App Group.
    /// Existing stores are never overwritten, changed, or removed.
    public static func migrateLegacyStorage(bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupIdentifierInfoKey) as? String,
              group.contains(".com.qssedalto.nexus") else { return }

        let legacyGroup = group.replacingOccurrences(of: ".com.qssedalto.nexus", with: ".com.prof18.slashgrab")
        if let oldDefaults = UserDefaults(suiteName: legacyGroup),
           let newDefaults = UserDefaults(suiteName: group) {
            for (key, value) in oldDefaults.dictionaryRepresentation() where newDefaults.object(forKey: key) == nil {
                newDefaults.set(value, forKey: key)
            }
        }

        if let legacyBundleID = bundle.bundleIdentifier?.replacingOccurrences(
            of: "com.qssedalto.nexus", with: "com.prof18.slashgrab"
        ), let legacyDefaults = UserDefaults(suiteName: legacyBundleID) {
            for (key, value) in legacyDefaults.dictionaryRepresentation() where UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        let manager = FileManager.default
        guard let oldDirectory = manager.containerURL(forSecurityApplicationGroupIdentifier: legacyGroup),
              let newDirectory = manager.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        for filename in ["NexusOperations.sqlite", "NexusStatistics.sqlite"] {
            let oldURL = oldDirectory.appendingPathComponent(filename)
            let newURL = newDirectory.appendingPathComponent(filename)
            guard manager.fileExists(atPath: oldURL.path), !manager.fileExists(atPath: newURL.path) else { continue }
            // SQLite's backup API copies a consistent snapshot, including uncheckpointed WAL data.
            var source: OpaquePointer?
            var destination: OpaquePointer?
            guard sqlite3_open_v2(oldURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let source else { if source != nil { sqlite3_close(source) }; continue }
            defer { sqlite3_close(source) }
            guard sqlite3_open_v2(newURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let destination else { if destination != nil { sqlite3_close(destination) }; continue }
            if let backup = sqlite3_backup_init(destination, "main", source, "main") {
                let result = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                sqlite3_close(destination)
                if result != SQLITE_DONE || finish != SQLITE_OK { try? manager.removeItem(at: newURL) }
            } else {
                sqlite3_close(destination)
                try? manager.removeItem(at: newURL)
            }
        }
    }

    public static func makeStore(bundle: Bundle = .main) -> AppSettingsStore? {
        makeStore(appGroupIdentifier: appGroupIdentifier(in: bundle))
    }

    public static func makeStore(appGroupIdentifier: String?) -> AppSettingsStore? {
        makeDefaults(appGroupIdentifier: appGroupIdentifier)
            .map(AppSettingsStore.init(defaults:))
    }

    public static func makePathFormatReader(bundle: Bundle = .main) -> SharedPathFormatReader? {
        makePathFormatReader(appGroupIdentifier: appGroupIdentifier(in: bundle))
    }

    public static func makePathFormatReader(appGroupIdentifier: String?) -> SharedPathFormatReader? {
        makeDefaults(appGroupIdentifier: appGroupIdentifier)
            .map(SharedPathFormatReader.init(defaults:))
    }

    public static func makeFinderExtensionVersionStore(bundle: Bundle = .main) -> SharedFinderExtensionVersionStore? {
        makeFinderExtensionVersionStore(appGroupIdentifier: appGroupIdentifier(in: bundle))
    }

    public static func makeFinderExtensionVersionStore(
        appGroupIdentifier: String?
    ) -> SharedFinderExtensionVersionStore? {
        makeDefaults(appGroupIdentifier: appGroupIdentifier)
            .map(SharedFinderExtensionVersionStore.init(defaults:))
    }

    public static func finderExtensionVersion(bundle: Bundle = .main) -> String? {
        guard let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }

        return "\(shortVersion) (\(buildNumber))"
    }

    private static func appGroupIdentifier(in bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: appGroupIdentifierInfoKey) as? String
    }

    private static func makeDefaults(appGroupIdentifier: String?) -> UserDefaults? {
        guard let appGroupIdentifier,
              !appGroupIdentifier.isEmpty,
              !appGroupIdentifier.contains("$(") else {
            return nil
        }

        return UserDefaults(suiteName: appGroupIdentifier)
    }
}

public final class SharedFinderExtensionVersionStore: @unchecked Sendable {
    private static let activeVersionKey = "activeFinderExtensionVersion"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func activate(version: String) {
        defaults.set(version, forKey: Self.activeVersionKey)
    }

    public func isActive(version: String) -> Bool {
        guard let activeVersion = defaults.string(forKey: Self.activeVersionKey) else {
            return true
        }

        return activeVersion == version
    }
}

public final class SharedPathFormatReader: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedFormat = PathFormat.shellEscaped

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        defaults.addObserver(
            self,
            forKeyPath: AppSettingsStore.selectedFormatKey,
            options: [.initial, .new],
            context: nil
        )
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: AppSettingsStore.selectedFormatKey)
    }

    public var selectedFormat: PathFormat {
        lock.lock()
        defer { lock.unlock() }
        return cachedFormat
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == AppSettingsStore.selectedFormatKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        let rawValue = change?[.newKey] as? String
        let format = rawValue.flatMap(PathFormat.init(rawValue:)) ?? .shellEscaped

        lock.lock()
        cachedFormat = format
        lock.unlock()
    }
}
