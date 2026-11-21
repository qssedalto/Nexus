import AppKit
import Foundation
import SlashgrabCore
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
        }
    }
    @Published private(set) var destinationSummary = ""
    @Published private(set) var status = ""
    @Published private(set) var lastBackup: Date?
    private let bookmarkKey = "nexusStatisticsBackupFolderBookmark"
    private var timer: Timer?
    private var working = false

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "nexusStatisticsCloudBackupEnabled")
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
        panel.message = localized("Choose an iCloud Drive directory for encrypted-by-transport macOS cloud file synchronization, or another backup folder. This file contains detailed statistics.")
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
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try Self.performBackup(store: store, bookmark: bookmark) }
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

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled,
              UserDefaults.standard.data(forKey: bookmarkKey) != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backupNow() }
        }
    }

    nonisolated private static func performBackup(
        store: InputStatisticsStore, bookmark: Data
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
        let file = folder.appendingPathComponent("NexusStatistics.sqlite")
        let temporary = folder.appendingPathComponent(
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
