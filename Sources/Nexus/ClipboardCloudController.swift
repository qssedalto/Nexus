import AppKit
import Foundation
import NexusCore
import SwiftUI

enum NexusSyncStorage: String, CaseIterable, Identifiable {
    case iCloudDrive
    case localFolder
    var id: String { rawValue }
}

/// Explicit, opt-in clipboard synchronization through a user-selected folder.
/// The system File Provider syncs that folder; no iCloud Drive API or entitlement
/// is requested. Old iCloud Drive journals and preferences are not opened.
@MainActor
final class ClipboardCloudController: ObservableObject {
    static let shared = ClipboardCloudController()

    @Published private(set) var storage: NexusSyncStorage

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "nexusFolderClipboardEnabled")
            configureAutomaticSyncTimer()
        }
    }
    /// Separate consent for timed iCloud Drive access. The default is OFF even
    /// when the user previously enabled manual iCloud clipboard sync.
    @Published var automaticSyncEnabled: Bool {
        didSet {
            defaults.set(automaticSyncEnabled, forKey: "nexusFolderClipboardAutomaticSync")
            configureAutomaticSyncTimer()
        }
    }
    @Published var includeNames: Bool {
        didSet { defaults.set(includeNames, forKey: "nexusFolderClipboardNames") }
    }
    @Published var includeText: Bool {
        didSet { defaults.set(includeText, forKey: "nexusFolderClipboardText") }
    }
    @Published var includePaths: Bool {
        didSet { defaults.set(includePaths, forKey: "nexusFolderClipboardPaths") }
    }
    /// Independent, revocable permission for image CKAsset transfer.
    @Published var includeImages: Bool {
        didSet { defaults.set(includeImages, forKey: "nexusFolderClipboardImages") }
    }
    @Published var includeFiles: Bool {
        didSet { defaults.set(includeFiles, forKey: "nexusFolderClipboardFiles") }
    }
    @Published private(set) var status = localized("Folder synchronization is off")
    @Published private(set) var nextHistoryOffset: Int
    @Published private(set) var pendingCount = 0
    @Published private(set) var cachedRecords: [ClipboardCloudRecord] = []
    @Published private(set) var running = false
    @Published private(set) var lastSuccessfulSync: ClipboardCloudRunSummary?

    private let defaults: UserDefaults
    private let deviceID: String
    private let journal: ClipboardCloudJournal?
    private let store: OperationStore?
    private let folderTokenNamespace = "NexusClipboardFolderV1"
    @Published private(set) var selectedFolderPath: String = ""
    @Published private(set) var folderPrepared = false
    @Published var pairingKeyEntry = ""
    @Published private(set) var pairingKeyConfigured = ClipboardFolderPairingKey.isConfigured()
    @Published private(set) var revealedPairingKey = ""
    private var selectedFolderURL: URL?
    private let maximumHistoryPage = 200
    private var automaticSyncTimer: Timer?
    private var automaticSyncTask: Task<Void, Never>?
    private var automaticCycleRunning = false

    private init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        storage = NexusSyncStorage(rawValue:
            defaults.string(forKey: "nexusFolderSyncStorage") ?? ""
        ) ?? .iCloudDrive
        lastSuccessfulSync = defaults.data(forKey: "nexusFolderClipboardLastSuccess")
            .flatMap { try? JSONDecoder().decode(ClipboardCloudRunSummary.self, from: $0) }
        enabled = defaults.bool(forKey: "nexusFolderClipboardEnabled") && ClipboardFolderPairingKey.isConfigured()
        automaticSyncEnabled = defaults.bool(forKey: "nexusFolderClipboardAutomaticSync")
        includeNames = defaults.bool(forKey: "nexusFolderClipboardNames")
        includeText = defaults.bool(forKey: "nexusFolderClipboardText")
        includePaths = defaults.bool(forKey: "nexusFolderClipboardPaths")
        includeImages = defaults.bool(forKey: "nexusFolderClipboardImages")
        includeFiles = defaults.bool(forKey: "nexusFolderClipboardFiles")
        nextHistoryOffset = max(0, defaults.integer(forKey: "nexusFolderClipboardHistoryOffset"))
        if let saved = defaults.string(forKey: "nexusFolderClipboardDeviceID"),
           UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            let newID = UUID().uuidString
            deviceID = newID
            defaults.set(newID, forKey: "nexusFolderClipboardDeviceID")
        }
        store = OperationStore.shared()
        if let home = SharedSettings.localDatabaseDirectory() {
            journal = try? ClipboardCloudJournal(
                url: home.appendingPathComponent("NexusClipboardFolderJournal.sqlite")
            )
        } else {
            journal = nil
        }
        restoreSelectedFolder()
        // An old enabled preference cannot authorize syncing an
        // uninitialized folder. The user must prepare it explicitly first.
        if !folderPrepared { enabled = false }
        refreshLocalCache()
        configureAutomaticSyncTimer()
    }

    /// The timer is created only under both independent user consents and a
    /// signed iCloud Drive configuration. A disabled toggle prevents future
    /// network attempts and cancels our scheduled in-flight task.
    private func configureAutomaticSyncTimer() {
        automaticSyncTimer?.invalidate()
        automaticSyncTimer = nil
        guard pairingKeyConfigured,
              ClipboardCloudAutomaticSyncPolicy.maySchedule(
            cloudEnabled: enabled,
            automaticEnabled: automaticSyncEnabled,
            containerConfigured: containerConfigured
        ) else {
            automaticSyncTask?.cancel()
            return
        }
        automaticSyncTimer = Timer.scheduledTimer(
            withTimeInterval: ClipboardCloudAutomaticSyncPolicy.intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
                          cloudEnabled: self.enabled,
                          automaticEnabled: self.automaticSyncEnabled,
                          containerConfigured: self.containerConfigured,
                          busy: self.running || self.automaticCycleRunning
                      ) else { return }
                self.automaticSyncTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runAutomaticSyncCycle()
                }
            }
        }
    }

    private func runAutomaticSyncCycle() async {
        guard !automaticCycleRunning,
              ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
                  cloudEnabled: enabled, automaticEnabled: automaticSyncEnabled,
                  containerConfigured: containerConfigured, busy: running
              ) else { return }
        automaticCycleRunning = true
        defer {
            automaticCycleRunning = false
            automaticSyncTask = nil
        }
        await prepareLocalPage()
        guard !Task.isCancelled, enabled, automaticSyncEnabled,
              containerConfigured else { return }
        await syncNow(automaticRun: true)
    }

    var currentConsent: ClipboardCloudConsent {
        ClipboardCloudConsent(
            enabled: enabled, includeText: includeText,
            includeNames: includeNames, includePaths: includePaths,
            includeImages: includeImages, includeFiles: includeFiles
        )
    }

    var containerConfigured: Bool { selectedFolderURL != nil }

    /// Changing the destination must not silently upload the old destination's
    /// pending journal into a different folder. Only local sync state is
    /// discarded; original clipboard history and either folder are untouched.
    private func resetDestinationJournal() -> Bool {
        guard !running else {
            status = localized("Finish the current sync before changing folders.")
            return false
        }
        do {
            try journal?.discardAllLocalCloudData()
        } catch {
            status = localized("Could not reset the local sync queue: ") + error.localizedDescription
            return false
        }
        enabled = false
        automaticSyncEnabled = false
        nextHistoryOffset = 0
        defaults.removeObject(forKey: "nexusFolderClipboardHistoryOffset")
        lastSuccessfulSync = nil
        defaults.removeObject(forKey: "nexusFolderClipboardLastSuccess")
        refreshLocalCache()
        return true
    }

    func changeStorage(to newStorage: NexusSyncStorage) {
        guard newStorage != storage, resetDestinationJournal() else { return }
        storage = newStorage
        defaults.set(newStorage.rawValue, forKey: "nexusFolderSyncStorage")
        selectedFolderURL = nil
        selectedFolderPath = ""
        folderPrepared = false
        defaults.removeObject(forKey: "nexusFolderSyncBookmark")
        status = localized("Choose a folder to continue.")
    }

    private func restoreSelectedFolder() {
        guard let bookmark = defaults.data(forKey: "nexusFolderSyncBookmark") else { return }
        var stale = false
        let location = (try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )) ?? (try? URL(
            resolvingBookmarkData: bookmark, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale
        ))
        guard let location,
              (storage == .localFolder
               || location.lastPathComponent == ClipboardFolderTransport.folderName) else {
            return
        }
        selectedFolderURL = location
        selectedFolderPath = location.path
        folderPrepared = FileManager.default.fileExists(
            atPath: location.appendingPathComponent(".nexus-folder-sync-v2").path
        )
    }

    /// Explicit user choice; iCloud mode requires the dedicated protocol
    /// folder. Local mode permits an arbitrary chosen folder but the transport
    /// still confines writes and deletes to Nexus-owned files inside it.
    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = localized("Choose sync folder")
        panel.message = localized(storage == .iCloudDrive
            ? "Select NexusClipboardSync in iCloud Drive."
            : "Choose a local folder for encrypted backups.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if storage == .iCloudDrive {
            let cloud = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            if FileManager.default.fileExists(atPath: cloud.path) {
                panel.directoryURL = cloud
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if storage == .iCloudDrive,
           url.lastPathComponent != ClipboardFolderTransport.folderName {
            status = localized("Select the folder named NexusClipboardSync")
            return
        }
        guard url.standardizedFileURL.path != "/",
              url.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL else {
            status = localized("Choose a dedicated folder, not the disk root or home folder.")
            return
        }
        do {
            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                bookmark = try url.bookmarkData(options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            guard resetDestinationJournal() else { return }
            defaults.set(bookmark, forKey: "nexusFolderSyncBookmark")
            selectedFolderURL = url
            selectedFolderPath = url.path
            folderPrepared = FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".nexus-folder-sync-v2").path
            )
            if !folderPrepared { enabled = false }
            status = localized(pairingKeyConfigured
                ? "Folder selected. Click Prepare folder before syncing."
                : "Folder selected. Generate a pairing key to continue.")
            configureAutomaticSyncTimer()
        } catch {
            status = "Could not remember selected folder: \(error.localizedDescription)"
        }
    }


    /// Generate a cryptographic key only when none exists. Never overwrite
    /// an installed secret implicitly: older synced data would become unreadable.
    func generatePairingKey() {
        guard !pairingKeyConfigured else {
            status = localized("An encryption key is already configured. Use Reveal to pair another device.")
            return
        }
        do {
            revealedPairingKey = try ClipboardFolderPairingKey.generate()
            pairingKeyConfigured = true
            status = localized("Pairing key saved in Keychain. Transfer it only to devices you trust.")
        } catch { status = "Pairing key generation failed: \(error.localizedDescription)" }
    }

    func installPairingKey() {
        do {
            try ClipboardFolderPairingKey.save(
                hex: pairingKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            pairingKeyEntry = ""
            revealedPairingKey = ""
            pairingKeyConfigured = true
            status = localized("Encryption key saved in Keychain")
        } catch { status = "Invalid pairing key: \(error.localizedDescription)" }
    }

    func revealPairingKey() {
        do {
            revealedPairingKey = try ClipboardFolderPairingKey.load()
                .map { String(format: "%02x", $0) }.joined()
            status = localized("Hide the pairing key once you have paired your other devices")
        } catch { status = "Cannot read pairing key: \(error.localizedDescription)" }
    }

    func hidePairingKey() { revealedPairingKey = "" }

    func copyPairingKey() {
        guard !revealedPairingKey.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(revealedPairingKey, forType: .string)
        ClipboardMonitor.shared.ignoreCurrentChange()
        status = localized("Pairing key copied. Clear the clipboard after securely transferring it.")
    }

    /// Stages one 200-record page and all local collections in an isolated
    /// utility task; the card UI never waits for SQLite/image work. This is a
    /// local preparatory action, not an implicit iCloud Drive upload.
    func prepareLocalPage() async {
        guard !running else { return }
        guard enabled else {
            status = localized("Enable sync first")
            return
        }
        guard let store, let journal else {
            status = localized("Local clipboard or journal database unavailable")
            return
        }
        running = true
        defer { running = false }
        do {
            let offset = nextHistoryOffset
            let deviceID = deviceID
            let consent = currentConsent
            let result = try await Task.detached(priority: .utility) {
                let page = try ClipboardCloudLocalSnapshot.stagePage(
                    from: store, in: journal, deviceID: deviceID,
                    consent: consent, offset: offset, limit: 200
                )
                let collectionCount = try ClipboardCloudLocalSnapshot.stageCollections(
                    from: store, in: journal, deviceID: deviceID,
                    consent: consent
                )
                return (page, collectionCount)
            }.value
            nextHistoryOffset = result.0.nextOffset ?? 0
            defaults.set(nextHistoryOffset, forKey: "nexusFolderClipboardHistoryOffset")
            refreshLocalCache()
            status = "Prepared \(result.0.staged) history records and \(result.1) collection changes locally"
        } catch {
            status = "Local preparation failed: \(error.localizedDescription)"
        }
    }

    func startSync() async {
        guard containerConfigured, pairingKeyConfigured else {
            status = localized("Choose a folder and create a pairing key first.")
            return
        }
        guard includeText || includeNames || includePaths else {
            status = localized("Select at least one type of content to sync.")
            return
        }
        if !folderPrepared {
            await prepareSelectedFolder()
        }
        guard folderPrepared else { return }
        enabled = true
        await syncIncludingLocalHistory()
    }

    /// The one user-facing sync action handles staging and transfer together.
    /// Do not require two obscure, consecutive buttons for each sync cycle.
    func syncIncludingLocalHistory() async {
        guard !running, enabled else { return }
        guard includeText || includeNames || includePaths else {
            status = localized("Select at least one type of content to sync.")
            return
        }
        await prepareLocalPage()
        guard !running else { return }
        await syncNow()
    }

    /// User-initiated folder initialization, not an Apple container request.
    func prepareSelectedFolder() async {
        guard !running, let selectedFolderURL else { return }
        running = true
        defer { running = false }
        do {
            let transport = try ClipboardFolderTransport(
                folderURL: selectedFolderURL, keyData: ClipboardFolderPairingKey.load(),
                allowSelectedLocalFolder: storage == .localFolder
            )
            try await transport.prepareFolderIfRequested()
            folderPrepared = true
            status = localized("NexusClipboardSync folder is ready")
        } catch {
            status = "Folder setup failed: \(error.localizedDescription)"
        }
    }

    func syncNow(automaticRun: Bool = false) async {
        guard !running else { return }
        guard enabled else { status = localized("Enable sync first"); return }
        guard containerConfigured, folderPrepared, pairingKeyConfigured else {
            status = localized("Generate a pairing key, prepare your chosen folder, then enable sync.")
            return
        }
        if automaticRun && (!automaticSyncEnabled || Task.isCancelled) { return }
        guard let journal else { status = localized("Folder journal unavailable"); return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let coordinator = try ClipboardCloudSyncCoordinator(
                journal: journal, transport: transport, zoneID: folderTokenNamespace
            )
            // Current privacy settings are rechecked when the coordinator
            // decides whether old, queued metadata can leave this Mac.
            let report = try await coordinator.syncOnce(consentProvider: { [weak self] in
                await MainActor.run {
                    guard let self, self.enabled,
                          (!automaticRun || self.automaticSyncEnabled),
                          !Task.isCancelled else { return ClipboardCloudConsent() }
                    return self.currentConsent
                }
            })
            if let summary = ClipboardCloudRunSummary(
                report: report,
                finishedTimeMS: Int64(Date().timeIntervalSince1970 * 1_000)
            ) {
                lastSuccessfulSync = summary
                if let encoded = try? JSONEncoder().encode(summary) {
                    defaults.set(encoded, forKey: "nexusFolderClipboardLastSuccess")
                }
            }
            refreshLocalCache()
            status = String(format: localized("Saved %d, received %d, remaining %d"),
                            report.uploaded, report.downloaded, report.pending) +
                (report.moreComing ? localized(" — more records on the next sync") : "")
        } catch {
            status = "Folder sync failed: \(error.localizedDescription)"
        }
    }

    /// User-invoked recovery from CKError.changeTokenExpired. This restarts
    /// incremental download and preserves local pending updates.
    func resetServerCursor() {
        guard !running, enabled, let journal else { return }
        do {
            try journal.resetChangeToken(forZone: folderTokenNamespace)
            status = localized("Sync position reset. The next manual sync will recheck the folder.")
            refreshLocalCache()
        } catch {
            status = "Could not reset sync cursor: \(error.localizedDescription)"
        }
    }

    /// Explicitly restore sanitized metadata/text from the local iCloud Drive
    /// journal into the normal history shelf. Never materializes remote file
    /// paths as working local file URL references.
    func restoreCachedHistory() async {
        guard !running, enabled else { return }
        guard let journal, let store else {
            status = localized("Clipboard history or cloud journal database unavailable")
            return
        }
        running = true
        defer { running = false }
        let consent = currentConsent
        do {
            let result = try await Task.detached(priority: .utility) {
                let cached = try journal.cachedRecords(limit: 100)
                let operations = try store.importCloudHistory(
                    cached, consent: consent, cloudImageProvider: { id in
                        try journal.cachedImage(recordID: id)
                    }
                )
                let collections = try store.importCloudCollections(
                    cached, consent: consent
                )
                return (operations, collections)
            }.value
            status = String(format: localized(
                "Restored %d cloud entries and %d collection changes to local history"
            ), result.0, result.1)
        } catch {
            status = "Cloud history restoration failed: \(error.localizedDescription)"
        }
    }

    func refreshLocalCache() {
        guard let journal else { return }
        do {
            cachedRecords = try journal.cachedRecords(limit: 100)
            pendingCount = try journal.pendingCount()
        } catch {
            status = "Cloud journal unavailable: \(error.localizedDescription)"
        }
    }

    /// A successful, explicit deletion in the local card UI can enqueue the
    /// corresponding cloud tombstone. No operation occurs when consent is off.
    func recordLocalDeletion(_ operationID: String) {
        guard enabled, let journal else { return }
        let deviceID = deviceID
        let consent = currentConsent
        Task.detached(priority: .utility) {
            _ = try? ClipboardCloudLocalSnapshot.stageDeletion(
                localOperationID: operationID, in: journal,
                deviceID: deviceID, consent: consent
            )
        }
    }

    /// Restore only an explicitly selected remote plain-text entry to the
    /// system clipboard. File placeholders and images cannot masquerade as
    /// valid original data on another Mac without a separate asset transfer.
    func copyRemoteText(_ record: ClipboardCloudRecord) {
        guard enabled, includeText, !record.isDeleted,
              case .operation(let operation)? = record.payload,
              operation.type == "text_copy", let text = operation.text else {
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            ClipboardMonitor.shared.ignoreCurrentChange()
            status = localized("Remote text copied to system clipboard")
        }
    }

    /// Removes cached iCloud-derived data from this Mac only. It never
    /// contacts iCloud and preserves original clipboard history/collections.
    /// The user must confirm from Settings before this method is invoked.
    func clearLocalCloudData() async {
        guard !running, let journal, let store else { return }
        enabled = false
        automaticSyncEnabled = false
        running = true
        defer { running = false }
        do {
            try await Self.discardLocalCloudData(journal: journal, store: store)
            resetCloudPreferencesAfterPurge()
            refreshLocalCache()
            status = localized("Local sync cache cleared; original clipboard history preserved")
        } catch {
            status = localized("Local cloud cache removal failed") + ": "
                + error.localizedDescription
        }
    }

    /// Erases the dedicated NexusClipboard private iCloud Drive zone ONLY after
    /// a separate typed confirmation in the settings sheet. Sync is disabled
    /// before network access to prevent any new local uploads during cleanup.
    /// If the network fails, the local journal remains available for retry.
    func eraseSyncedFolderData(confirmation: String) async {
        guard confirmation == "DELETE", !running,
              let journal, let store else { return }
        enabled = false
        automaticSyncEnabled = false
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let purge = ClipboardCloudPurgeCoordinator(
                transport: transport, journal: journal
            )
            try await purge.purgeCloudZoneAndLocalCache(
                confirmation: confirmation,
                afterRemoteDeletion: {
                    // If local mirror removal fails, preserve iCloud Drive's
                    // outbox and cursor for a safe, idempotent retry.
                    _ = try store.discardImportedCloudMirrors()
                }
            )
            resetCloudPreferencesAfterPurge()
            refreshLocalCache()
            status = localized("Nexus sync records deleted from this folder. Other devices may add them again.")
        } catch {
            status = localized("Folder deletion failed; sync remains disabled and local recovery data may remain")
                + ": " + error.localizedDescription
        }
    }

    private static func discardLocalCloudData(
        journal: ClipboardCloudJournal, store: OperationStore
    ) async throws {
        try await Task.detached(priority: .utility) {
            // Keep the journal for retry if local mirror removal fails.
            _ = try store.discardImportedCloudMirrors()
            try journal.discardAllLocalCloudData()
        }.value
    }

    private func resetCloudPreferencesAfterPurge() {
        includeText = false
        includeNames = false
        includePaths = false
        includeImages = false
        includeFiles = false
        nextHistoryOffset = 0
        defaults.removeObject(forKey: "nexusFolderClipboardHistoryOffset")
        lastSuccessfulSync = nil
        defaults.removeObject(forKey: "nexusFolderClipboardLastSuccess")
    }

    /// User-triggered local export of a verified iCloud Drive file asset.
    /// Never writes a remote path or file name to disk without SavePanel.
    func saveCachedRemoteFile(recordID: String) {
        guard enabled, includeFiles, let journal else { return }
        do {
            guard let file = try journal.cachedFile(recordID: recordID) else {
                status = localized("Cloud file not available locally")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.reference.fileName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else {
                return
            }
            try file.bytes.write(to: destination, options: .atomic)
            status = localized("Cloud file exported")
        } catch {
            status = localized("Cloud file export failed") + ": "
                + error.localizedDescription
        }
    }

    private func makeTransport() async throws -> ClipboardFolderTransport {
        enum Availability: Error { case missingSelectedFolder }
        guard let selectedFolderURL else { throw Availability.missingSelectedFolder }
        return try ClipboardFolderTransport(
            folderURL: selectedFolderURL, keyData: ClipboardFolderPairingKey.load(),
            allowSelectedLocalFolder: storage == .localFolder
        )
    }
}
