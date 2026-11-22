import AppKit
import CryptoKit
import Foundation
import NexusCore
import SwiftUI

/// User-selected-folder automatic database backup. Choosing iCloud Drive as
/// the destination allows macOS File Provider to sync the backup without
/// granting a new CloudKit entitlement or silently uploading key statistics.
/// This is a backup, NOT an authenticated multi-device merge engine.
@MainActor
final class InputCloudBackupController: ObservableObject {
    static let shared = InputCloudBackupController()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nexusStatisticsCloudBackupEnabled")
            schedule()
            if enabled && !oldValue { backupNow() }
        }
    }
    @Published private(set) var destinationSummary = ""
    @Published private(set) var status = ""
    @Published private(set) var lastBackup: Date?
    @Published private(set) var restoring = false
    @Published var importOtherMacBackups: Bool {
        didSet {
            UserDefaults.standard.set(importOtherMacBackups, forKey: "nexusStatisticsAutoImportOtherMacs")
            schedule()
        }
    }
    @Published private(set) var importStatus = ""
    private var importWorking = false
    private let bookmarkKey = "nexusStatisticsBackupFolderBookmark"
    private let backupDeviceIDKey = "nexusStatisticsBackupDeviceID"
    private var timer: Timer?
    private var working = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "nexusStatisticsCloudBackupEnabled")
        importOtherMacBackups = defaults.bool(forKey: "nexusStatisticsAutoImportOtherMacs")
        lastBackup = defaults.object(forKey: "nexusStatisticsLastBackup") as? Date
        destinationSummary = defaults.data(forKey: bookmarkKey) == nil
            ? localized("No backup folder selected")
            : localized("User-selected folder")
        schedule()
    }

    func selectDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = localized("Use this folder")
        panel.message = localized("Choose an iCloud Drive directory for automatic file backup (or another folder). The saved SQLite file contains detailed event timestamps.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            destinationSummary = url.path
            status = localized("Backup folder saved; no statistics uploaded yet")
            schedule()
        } catch {
            status = error.localizedDescription
        }
    }

    func backupNow() {
        guard !working, let store = InputStatisticsStore.shared(),
              let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            status = localized("Choose a backup folder before enabling cloud backup")
            return
        }
        working = true
        status = localized("Saving statistics backup")
        let deviceID = persistentBackupDeviceID()
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try Self.performBackup(store: store, bookmark: bookmark, deviceID: deviceID) }
            }.value
            working = false
            switch result {
            case .success(let directory):
                let now = Date()
                lastBackup = now
                UserDefaults.standard.set(now, forKey: "nexusStatisticsLastBackup")
                destinationSummary = directory.path
                status = localized("Statistics backup complete")
                // Make only the new folder use Nexus's App icon; do not
                // change the parent iCloud Drive folder or user files.
                let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
                _ = NSWorkspace.shared.setIcon(appIcon, forFile: directory.path, options: [])
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private func persistentBackupDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: backupDeviceIDKey),
           UUID(uuidString: existing) != nil { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: backupDeviceIDKey)
        return id
    }

    func restoreSelectedBackup() {
        guard !restoring, let store = InputStatisticsStore.shared() else {
            status = localized("Statistics database unavailable")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = localized("Restore selected statistics")
        panel.message = localized("Select one NexusStatistics.sqlite file inside a Nexus Statistics device folder. Restoring merges old records, preserving current data.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "NexusStatistics.sqlite" else {
            status = localized("Select a NexusStatistics.sqlite backup file")
            return
        }
        restoring = true
        status = localized("Restoring historical statistics")
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try Self.performRestore(from: url, into: store) }
            }.value
            restoring = false
            switch result {
            case .success(let imported):
                status = "\(localized("Restored statistical rows")): \(imported)"
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    nonisolated private static func performRestore(
        from selected: URL, into store: InputStatisticsStore
    ) throws -> Int {
        let accessed = selected.startAccessingSecurityScopedResource()
        defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
        let parent = selected.deletingLastPathComponent().lastPathComponent
        let sourceID: String
        if UUID(uuidString: parent) != nil {
            sourceID = "icloud:" + parent
        } else {
            // Stable fallback for older single-file backups; never persist
            // their original file path in a restored statistics record.
            let digest = SHA256.hash(data: Data(selected.path.utf8))
            sourceID = "icloudlegacy:" + digest.prefix(16)
                .map { String(format: "%02x", $0) }.joined()
        }
        return try store.restoreBackup(from: selected, deviceID: sourceID)
    }

    func importOtherMacSnapshotsNow() {
        guard !importWorking,
              let store = InputStatisticsStore.shared(),
              let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            importStatus = localized("Choose a backup folder before importing other Macs")
            return
        }
        let myID = persistentBackupDeviceID()
        importWorking = true
        importStatus = localized("Scanning other Mac backups")
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    try Self.importOtherSnapshots(
                        store: store, bookmark: bookmark, localDeviceID: myID
                    )
                }
            }.value
            importWorking = false
            switch result {
            case .success(let inserted):
                importStatus = "\(localized("Imported cross-device statistical rows")): \(inserted)"
            case .failure(let error):
                importStatus = error.localizedDescription
            }
        }
    }

    nonisolated private static func importOtherSnapshots(
        store: InputStatisticsStore, bookmark: Data, localDeviceID: String
    ) throws -> Int {
        var stale = false
        let root = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw BackupError.staleBookmark }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        let folder = root.appendingPathComponent("Nexus Statistics", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var imported = 0
        for directory in entries.prefix(40) {
            let name = directory.lastPathComponent
            guard name != localDeviceID, UUID(uuidString: name) != nil,
                  let info = try? directory.resourceValues(forKeys: [
                      .isDirectoryKey, .isSymbolicLinkKey
                  ]),
                  info.isDirectory == true, info.isSymbolicLink != true else { continue }
            let backup = directory.appendingPathComponent("NexusStatistics.sqlite")
            guard let metadata = try? backup.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey
            ]), metadata.isRegularFile == true,
                  metadata.isSymbolicLink != true,
                  let bytes = metadata.fileSize, bytes > 0,
                  bytes <= 100_000_000 else { continue }
            // No directory recursion, no heavyweight cloud file data scan.
            // A File Provider may require downloading this opted-in snapshot.
            imported += try store.restoreBackup(from: backup, deviceID: "icloud:" + name)
        }
        return imported
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled,
              UserDefaults.standard.data(forKey: bookmarkKey) != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.importOtherMacBackups == true {
                    self?.importOtherMacSnapshotsNow()
                }
                self?.backupNow()
            }
        }
        if lastBackup?.timeIntervalSinceNow ?? -7200 < -3600 {
            Task { @MainActor [weak self] in
                if self?.importOtherMacBackups == true {
                    self?.importOtherMacSnapshotsNow()
                }
                self?.backupNow()
            }
        }
    }

    nonisolated private static func performBackup(
        store: InputStatisticsStore, bookmark: Data, deviceID: String
    ) throws -> URL {
        var stale = false
        let root = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw BackupError.staleBookmark }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        let folder = root.appendingPathComponent("Nexus Statistics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        // Separate subfolders prevent different Macs from overwriting each
        // other's snapshots when they select the same iCloud directory.
        let deviceFolder = folder.appendingPathComponent(deviceID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: deviceFolder, withIntermediateDirectories: true
        )
        let file = deviceFolder.appendingPathComponent("NexusStatistics.sqlite")
        let temporary = deviceFolder.appendingPathComponent(
            ".NexusStatistics-\(UUID().uuidString).tmp"
        )
        do {
            try store.backup(to: temporary)
            if FileManager.default.fileExists(atPath: file.path) {
                // Do not remove the last good backup until a complete
                // SQLite online-backup snapshot has been produced.
                _ = try FileManager.default.replaceItemAt(
                    file, withItemAt: temporary, backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return folder
    }

    private enum BackupError: LocalizedError {
        case staleBookmark
        var errorDescription: String? {
            localized("Backup folder access expired; select the folder again")
        }
    }
}
