import Foundation
import NexusMobileCore
import SwiftUI
import UIKit

/// Universal iOS/iPadOS client. iOS cannot passively monitor another app's
/// clipboard, so text is read ONLY on a direct button press in the foreground.
@MainActor
final class MobileClipboardController: ObservableObject {
    @Published var cloudEnabled: Bool {
        didSet { defaults.set(cloudEnabled, forKey: "nexusMobileFolderEnabled") }
    }
    /// Foreground-only network sync; never implies a pasteboard read.
    @Published var foregroundSyncEnabled: Bool {
        didSet {
            defaults.set(foregroundSyncEnabled, forKey: "nexusMobileForegroundSync")
        }
    }
    @Published var includeText: Bool {
        didSet { defaults.set(includeText, forKey: "nexusMobileFolderText") }
    }
    @Published var includeNames: Bool {
        didSet { defaults.set(includeNames, forKey: "nexusMobileFolderNames") }
    }
    @Published var includePaths: Bool {
        didSet { defaults.set(includePaths, forKey: "nexusMobileFolderPaths") }
    }
    @Published var includeImages: Bool {
        didSet { defaults.set(includeImages, forKey: "nexusMobileFolderImages") }
    }
    @Published var includeFiles: Bool {
        didSet { defaults.set(includeFiles, forKey: "nexusMobileFolderFiles") }
    }
    @Published private(set) var records: [ClipboardCloudRecord] = []
    @Published private(set) var localEntries: [MobileLocalClipboardEntry] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var status = NSLocalizedString("iCloud clipboard sync is idle", comment: "")
    @Published private(set) var running = false
    @Published private(set) var lastSuccessfulSync: ClipboardCloudRunSummary?

    private let defaults: UserDefaults
    private let journal: ClipboardCloudJournal?
    private let localStore: MobileClipboardLocalStore?
    private let deviceID: String
    private let folderTokenNamespace = "NexusClipboardFolderV1"
    @Published private(set) var selectedFolderLabel: String = ""
    private var selectedFolderURL: URL?
    private var lastForegroundSyncAttempt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastSuccessfulSync = defaults.data(forKey: "nexusMobileFolderLastSuccess")
            .flatMap { try? JSONDecoder().decode(ClipboardCloudRunSummary.self, from: $0) }
        cloudEnabled = defaults.bool(forKey: "nexusMobileFolderEnabled")
        foregroundSyncEnabled = defaults.bool(forKey: "nexusMobileForegroundSync")
        includeText = defaults.bool(forKey: "nexusMobileFolderText")
        includeNames = defaults.bool(forKey: "nexusMobileFolderNames")
        includePaths = defaults.bool(forKey: "nexusMobileFolderPaths")
        includeImages = defaults.bool(forKey: "nexusMobileFolderImages")
        includeFiles = defaults.bool(forKey: "nexusMobileFolderFiles")
        if let existing = defaults.string(forKey: "nexusMobileFolderDeviceID"),
           UUID(uuidString: existing) != nil {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: "nexusMobileFolderDeviceID")
            deviceID = generated
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            journal = try? ClipboardCloudJournal(
                url: support.appendingPathComponent("NexusMobileFolderJournal.sqlite")
            )
            localStore = try? MobileClipboardLocalStore(
                url: support.appendingPathComponent("NexusMobileLocalHistory.sqlite")
            )
        } else {
            journal = nil
            localStore = nil
        }
        restoreSelectedFolder()
        refresh()
    }

    var containerConfigured: Bool { selectedFolderURL != nil }

    /// The system document picker grants access to this selected directory.
    func selectSyncFolder(_ url: URL) {
        guard url.lastPathComponent == ClipboardFolderTransport.folderName else {
            status = "Select the folder named NexusClipboardSync"
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            defaults.set(bookmark, forKey: "nexusMobileFolderBookmark")
            selectedFolderURL = url
            selectedFolderLabel = url.lastPathComponent
            status = "Folder selected. Prepare it before syncing."
        } catch {
            status = "Could not remember selected folder: \\(error.localizedDescription)"
        }
    }

    private func restoreSelectedFolder() {
        guard let bookmark = defaults.data(forKey: "nexusMobileFolderBookmark") else {
            return
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale, url.lastPathComponent == ClipboardFolderTransport.folderName else {
            return
        }
        selectedFolderURL = url
        selectedFolderLabel = url.lastPathComponent
    }

    private var consent: ClipboardCloudConsent {
        ClipboardCloudConsent(
            enabled: cloudEnabled, includeText: includeText,
            includeNames: includeNames, includePaths: includePaths,
            includeImages: includeImages, includeFiles: includeFiles
        )
    }

    /// Explicit iOS clipboard read; nothing is sampled in the background,
    /// on app launch, from notifications or by SwiftUI rendering.
    func importClipboardText() {
        guard let localStore else {
            status = NSLocalizedString("Local clipboard database unavailable", comment: "")
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            status = NSLocalizedString("The clipboard contains no text", comment: "")
            return
        }
        guard text.utf8.count <= MobileClipboardLocalStore.maximumTextBytes else {
            status = NSLocalizedString("Copied text is above the 64 KB content safety limit", comment: "")
            return
        }
        let stamp = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            let saved = try localStore.recordText(
                text, detectedTimeMS: stamp
            )
            // A successful user-triggered local save is independent of
            // CloudKit consent. folder staging requires explicit opt-in.
            if cloudEnabled, let journal {
                let local = RecordedOperation(
                    id: saved.id, detectedTimeMS: stamp, clipboardText: text
                )
                if let payload = ClipboardCloudOperation(
                    record: local, consent: consent
                ), let revision = ClipboardCloudRevision.next(
                    deviceID: deviceID, after: nil
                ) {
                    let change = ClipboardCloudRecord(
                        id: ClipboardCloudRecord.operationID(saved.id),
                        kind: .operation, revision: revision,
                        payload: .operation(payload)
                    )
                    try journal.stageLocal(change)
                    status = NSLocalizedString("Saved locally and queued for manual iCloud sync", comment: "")
                } else {
                    status = NSLocalizedString("Saved locally, cloud metadata unavailable", comment: "")
                }
            } else {
                status = NSLocalizedString("Saved to local clipboard history (iCloud off)", comment: "")
            }
            refresh()
        } catch {
            status = "Could not save clipboard entry: \(error.localizedDescription)"
        }
    }

    func copyLocalText(_ entry: MobileLocalClipboardEntry) {
        UIPasteboard.general.string = entry.text
        status = NSLocalizedString("Local text copied to system clipboard", comment: "")
    }

    func deleteLocalText(_ entry: MobileLocalClipboardEntry) {
        guard let localStore else { return }
        do {
            guard try localStore.delete(id: entry.id) else { return }
            // Only a previously staged cloud entry gets a tombstone, and only
            // under the currently authorized sync settings.
            if cloudEnabled, let journal,
               let prior = try journal.record(
                id: ClipboardCloudRecord.operationID(entry.id)
               ), !prior.isDeleted,
               let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: prior.revision
               ) {
                try journal.stageLocal(prior.tombstone(revision: revision))
            }
            refresh()
            status = cloudEnabled
                ? NSLocalizedString("Local entry deleted; cloud tombstone queued when applicable", comment: "")
                : NSLocalizedString("Local clipboard entry deleted", comment: "")
        } catch {
            status = "Could not delete local entry: \(error.localizedDescription)"
        }
    }

    func createCollection(named proposed: String) {
        guard cloudEnabled, includeNames, let journal else {
            status = NSLocalizedString("Allow collection names before saving a collection", comment: "")
            return
        }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 50 else {
            status = NSLocalizedString("Collection name must contain 1–50 characters", comment: "")
            return
        }
        let uuid = UUID().uuidString
        guard let revision = ClipboardCloudRevision.next(
            deviceID: deviceID, after: nil
        ) else { return }
        let record = ClipboardCloudRecord(
            id: ClipboardCloudRecord.collectionID(uuid),
            kind: .collection, revision: revision,
            payload: .collection(ClipboardCloudCollection(name: name))
        )
        do {
            try journal.stageLocal(record)
            refresh()
            status = NSLocalizedString("Permanent collection staged locally", comment: "")
        } catch {
            status = "Cannot create collection: \(error.localizedDescription)"
        }
    }

    func addToCollection(operation: ClipboardCloudRecord,
                         collection: ClipboardCloudRecord) {
        guard cloudEnabled, includeNames, let journal,
              !operation.isDeleted, !collection.isDeleted,
              operation.kind == .operation, collection.kind == .collection else { return }
        let collectionID = String(collection.id.dropFirst("collection:".count))
        let operationID = String(operation.id.dropFirst("operation:".count))
        let id = ClipboardCloudRecord.membershipID(
            collectionID: collectionID, operationID: operationID
        )
        do {
            let previous = try journal.record(id: id)
            guard let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: previous?.revision
            ) else { return }
            let rank = Int64(Date().timeIntervalSince1970 * 1000)
            let next = ClipboardCloudRecord(
                id: id, kind: .membership, revision: revision,
                payload: .membership(ClipboardCloudMembership(
                    collectionID: collectionID,
                    operationID: operationID, sortPosition: rank
                ))
            )
            try journal.stageLocal(next)
            refresh()
            status = NSLocalizedString("Added to permanent collection", comment: "")
        } catch {
            status = "Cannot update collection: \(error.localizedDescription)"
        }
    }

    func deleteLocalAndCloud(_ record: ClipboardCloudRecord) {
        guard cloudEnabled, let journal else { return }
        do {
            guard let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: record.revision
            ) else { return }
            try journal.stageLocal(record.tombstone(revision: revision))
            refresh()
            status = NSLocalizedString("Deleted locally; tombstone queued for next sync", comment: "")
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    func copyText(_ record: ClipboardCloudRecord) {
        guard !record.isDeleted,
              case .operation(let op)? = record.payload,
              let body = op.text, includeText else { return }
        UIPasteboard.general.string = body
        status = NSLocalizedString("Text copied to system clipboard", comment: "")
    }

    func prepareSelectedFolder() async {
        guard !running, let selectedFolderURL else { return }
        running = true
        defer { running = false }
        do {
            try await ClipboardFolderTransport(folderURL: selectedFolderURL)
                .prepareFolderIfRequested()
            status = "NexusClipboardSync folder is ready"
        } catch {
            status = "Could not prepare folder: \\(error.localizedDescription)"
        }
    }

    /// Invoked only when the scene becomes active or the user explicitly
    /// enables this feature in the foreground. No background task is created.
    func syncWhenForegroundEligible() async {
        let now = Date()
        guard ClipboardCloudForegroundSyncPolicy.mayAttempt(
            cloudEnabled: cloudEnabled,
            foregroundEnabled: foregroundSyncEnabled,
            containerConfigured: containerConfigured,
            busy: running,
            lastAttempt: lastForegroundSyncAttempt,
            now: now
        ) else { return }
        lastForegroundSyncAttempt = now
        await syncNow(automaticForegroundRun: true)
    }

    func syncNow(automaticForegroundRun: Bool = false) async {
        guard !running, cloudEnabled, let journal else { return }
        if automaticForegroundRun && !foregroundSyncEnabled { return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let coordinator = try ClipboardCloudSyncCoordinator(
                journal: journal, transport: transport, zoneID: folderTokenNamespace
            )
            let report = try await coordinator.syncOnce(consentProvider: { [weak self] in
                await MainActor.run {
                    guard let self, self.cloudEnabled,
                          (!automaticForegroundRun || self.foregroundSyncEnabled)
                    else { return ClipboardCloudConsent() }
                    return self.consent
                }
            })
            if let summary = ClipboardCloudRunSummary(
                report: report,
                finishedTimeMS: Int64(Date().timeIntervalSince1970 * 1_000)
            ) {
                lastSuccessfulSync = summary
                if let encoded = try? JSONEncoder().encode(summary) {
                    defaults.set(encoded, forKey: "nexusMobileFolderLastSuccess")
                }
            }
            refresh()
            status = "Uploaded \(report.uploaded), received \(report.downloaded), pending \(report.pending)"
                + (report.moreComing ? " — more pages available" : "")
        } catch {
            status = "Sync unavailable: \(error.localizedDescription)"
        }
    }

    func resetServerCursor() {
        guard !running, cloudEnabled, let journal else { return }
        do {
            try journal.resetChangeToken(forZone: folderTokenNamespace)
            status = NSLocalizedString("Sync cursor reset; next sync replays remote changes", comment: "")
            refresh()
        } catch {
            status = "Cannot reset cursor: \(error.localizedDescription)"
        }
    }

    /// Read only a previously downloaded, verified image from the private
    /// folder sync cache. No remote network or system pasteboard read occurs.
    /// For a user-triggered document exporter only. The original file name
    /// has been validated and remote binary bytes remain in the app cache.
    func cachedRemoteFile(recordID: String) -> ClipboardCloudFileAsset? {
        guard cloudEnabled, includeFiles,
              let journal else { return nil }
        return try? journal.cachedFile(recordID: recordID)
    }

    func cachedRemoteImage(recordID: String) -> Data? {
        guard cloudEnabled, includeImages,
              let journal,
              let asset = try? journal.cachedImage(recordID: recordID) else {
            return nil
        }
        return asset.bytes
    }

    func copyRemoteImage(recordID: String) {
        guard let bytes = cachedRemoteImage(recordID: recordID),
              let image = UIImage(data: bytes) else {
            status = NSLocalizedString("Cloud image unavailable", comment: "")
            return
        }
        UIPasteboard.general.image = image
        status = NSLocalizedString("Cloud image copied to clipboard", comment: "")
    }

    func refresh() {
        if let localStore {
            do {
                localEntries = try localStore.recent(limit: 500)
            } catch {
                status = "Could not load local clipboard history: \(error.localizedDescription)"
            }
        }
        guard let journal else { return }
        do {
            records = try journal.cachedRecords(limit: 200)
            pendingCount = try journal.pendingCount()
        } catch {
            status = "Could not load local cloud cache: \(error.localizedDescription)"
        }
    }

    /// Explicit offline-only removal of folder sync cache/outbox/cursors.
    /// The separately saved iPhone/iPad local clipboard history is retained.
    func clearLocalCloudData() async {
        guard !running, let journal else { return }
        cloudEnabled = false
        foregroundSyncEnabled = false
        running = true
        defer { running = false }
        do {
            try await Task.detached(priority: .utility) {
                try journal.discardAllLocalCloudData()
            }.value
            resetCloudPreferencesAfterPurge()
            refresh()
            status = NSLocalizedString(
                "Local cloud cache cleared; offline clipboard history preserved",
                comment: ""
            )
        } catch {
            status = "Cloud cache deletion failed: \(error.localizedDescription)"
        }
    }

    /// Explicitly erases the dedicated Nexus private iCloud zone after the
    /// UI obtains a separate typed confirmation. No background invocation.
    func eraseSyncedFolderData(confirmation: String) async {
        guard confirmation == "DELETE", !running, let journal else { return }
        cloudEnabled = false
        foregroundSyncEnabled = false
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let purge = ClipboardCloudPurgeCoordinator(
                transport: transport, journal: journal
            )
            try await purge.purgeCloudZoneAndLocalCache(
                confirmation: confirmation
            )
            resetCloudPreferencesAfterPurge()
            refresh()
            status = NSLocalizedString(
                "Nexus folder sync records deleted. Disable syncing on other devices.",
                comment: ""
            )
        } catch {
            status = "Cloud deletion failed; sync remains disabled: "
                + error.localizedDescription
        }
    }

    private func resetCloudPreferencesAfterPurge() {
        includeText = false
        includeNames = false
        includePaths = false
        includeImages = false
        includeFiles = false
        lastSuccessfulSync = nil
        defaults.removeObject(forKey: "nexusMobileFolderLastSuccess")
    }

    private func makeTransport() async throws -> ClipboardFolderTransport {
        enum Unavailable: Error { case missingSelectedFolder }
        guard let selectedFolderURL else { throw Unavailable.missingSelectedFolder }
        return ClipboardFolderTransport(folderURL: selectedFolderURL)
    }
}
