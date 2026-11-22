import Foundation
import SQLite3

public enum SharedSettings {
    public static let appGroupIdentifierInfoKey = "NexusAppGroupIdentifier"
    public static let finderCopyNotification = Notification.Name("com.qssedalto.nexus.finderCopyCompleted")

    /// Drive builds signed ad-hoc may not have an authorized App Group.
    /// In that case NEVER silently drop all local clipboard/statistics
    /// records: store them in the user Application Support directory for
    /// this *isolated* bundle ID. Production/CloudKit editions retain their
    /// normal App Group behavior. Existing fallback records keep precedence
    /// if an App Group later becomes available after a signing change.
    public static func localDatabaseDirectory(bundle: Bundle = .main) -> URL? {
        let group = bundle.object(forInfoDictionaryKey: appGroupIdentifierInfoKey) as? String
        let groupDirectory = group.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        guard bundle.bundleIdentifier == "com.qssedalto.nexus.drive.dev" else {
            return groupDirectory
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return groupDirectory }
        let fallback = support.appendingPathComponent(
            "com.qssedalto.nexus.drive.dev", isDirectory: true
        )
        let history = fallback.appendingPathComponent("NexusOperations.sqlite")
        let statistics = fallback.appendingPathComponent("NexusStatistics.sqlite")
        let journal = fallback.appendingPathComponent("NexusClipboardFolderJournal.sqlite")
        if FileManager.default.fileExists(atPath: history.path)
            || FileManager.default.fileExists(atPath: statistics.path)
            || FileManager.default.fileExists(atPath: journal.path) {
            return fallback
        }
        return groupDirectory ?? fallback
    }


    // The old group is read-only during the move. We never delete old data or overwrite new data.
    private static let legacySettingsKeys = [
        "historyEntries", "historyLimit", "selectedPathFormat",
        "launchAtLoginEnabled", "useFinderSubmenu", "nexusFeedbackDuration",
    ]
    private static let legacyApplicationKeys = legacySettingsKeys + [
        "nexusInputPaused", "nexusCountKeyRepeats", "nexusMonitorFileCopies",
        "nexusSyncServer", "nexusSyncAutomatic", "nexusSyncPreciseEvents",
        "nexusSyncLastSuccess", "nexusSyncDeviceID",
    ]

    public static func migrateLegacyStorage(bundle: Bundle = .main) {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier.hasPrefix("com.qssedalto.nexus"),
              let newGroup = appGroupIdentifier(in: bundle),
              newGroup.contains(".com.qssedalto.nexus") else { return }

        let oldGroup = newGroup.replacingOccurrences(
            of: ".com.qssedalto.nexus", with: ".com.prof18.slashgrab"
        )
        let oldBundleIdentifier = bundleIdentifier.replacingOccurrences(
            of: "com.qssedalto.nexus", with: "com.prof18.slashgrab",
            options: .anchored
        )

        if let source = UserDefaults(suiteName: oldGroup),
           let destination = UserDefaults(suiteName: newGroup) {
            copyMissingDefaults(from: source, to: destination, keys: legacySettingsKeys)
        }
        if let source = UserDefaults(suiteName: oldBundleIdentifier) {
            copyMissingDefaults(from: source, to: .standard, keys: legacyApplicationKeys)
        }

        let manager = FileManager.default
        guard let oldDirectory = manager.containerURL(forSecurityApplicationGroupIdentifier: oldGroup),
              let newDirectory = manager.containerURL(forSecurityApplicationGroupIdentifier: newGroup) else {
            return
        }

        for filename in ["NexusOperations.sqlite", "NexusStatistics.sqlite"] {
            _ = backupSQLiteIfAbsent(
                from: oldDirectory.appendingPathComponent(filename),
                to: newDirectory.appendingPathComponent(filename)
            )
        }
    }

    private static func copyMissingDefaults(from source: UserDefaults, to destination: UserDefaults, keys: [String]) {
        for key in keys where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) {
                destination.set(value, forKey: key)
            }
        }
    }

    // Internal for unit testing without relying on machine-specific application-group entitlements.
    // A temporary, verified SQLite snapshot is moved into place only after the copy succeeds.
    @discardableResult
    static func backupSQLiteIfAbsent(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceURL.path),
              !manager.fileExists(atPath: destinationURL.path) else { return false }

        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".nexus-migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? manager.removeItem(at: URL(fileURLWithPath: temporaryURL.path + suffix))
            }
        }

        guard copySQLiteSnapshot(from: sourceURL, to: temporaryURL) else { return false }
        guard !manager.fileExists(atPath: destinationURL.path) else { return false }

        do {
            try manager.moveItem(at: temporaryURL, to: destinationURL)
            return true
        } catch {
            return false
        }
    }

    private static func copySQLiteSnapshot(from sourceURL: URL, to destinationURL: URL) -> Bool {
        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(
            sourceURL.path, &sourceHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let source = sourceHandle else {
            if let sourceHandle { sqlite3_close(sourceHandle) }
            return false
        }
        defer { sqlite3_close(source) }

        var destinationHandle: OpaquePointer?
        guard sqlite3_open_v2(
            destinationURL.path, &destinationHandle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let destination = destinationHandle else {
            if let destinationHandle { sqlite3_close(destinationHandle) }
            return false
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            return false
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else { return false }

        // The old database may use WAL. Make the migrated file standalone before
        // moving it, so no temporary -wal/-shm sidecar is required to read it.
        guard sqlite3_exec(
            destination, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;",
            nil, nil, nil
        ) == SQLITE_OK else { return false }

        var checkStatement: OpaquePointer?
        guard sqlite3_prepare_v2(destination, "PRAGMA quick_check", -1, &checkStatement, nil) == SQLITE_OK,
              let check = checkStatement else {
            if let checkStatement { sqlite3_finalize(checkStatement) }
            return false
        }
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, let resultText = sqlite3_column_text(check, 0) else {
            return false
        }
        return String(cString: resultText) == "ok"
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
