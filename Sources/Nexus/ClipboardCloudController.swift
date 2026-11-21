import AppKit
import CloudKit
import Foundation
import NexusCore
import SwiftUI

/// CloudKit clipboard integration. Network access is manual unless the user
/// explicitly enables the separate scheduled sync control. Simply opening
/// Settings never contacts CloudKit. A signed app must supply
/// NexusCloudKitContainerIdentifier in Info.plist.
@MainActor
final class ClipboardCloudController: ObservableObject {
    static let shared = ClipboardCloudController()

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "nexusCloudClipboardEnabled")
            configureAutomaticSyncTimer()
        }
    }
    /// Separate consent for timed CloudKit access. The default is OFF even
    /// when the user previously enabled manual iCloud clipboard sync.
    @Published var automaticSyncEnabled: Bool {
        didSet {
            defaults.set(automaticSyncEnabled, forKey: "nexusCloudClipboardAutomaticSync")
            configureAutomaticSyncTimer()
        }
    }
    @Published var includeNames: Bool {
        didSet { defaults.set(includeNames, forKey: "nexusCloudClipboardNames") }
    }
    @Published var includeText: Bool {
        didSet { defaults.set(includeText, forKey: "nexusCloudClipboardText") }
    }
    @Published var includePaths: Bool {
        didSet { defaults.set(includePaths, forKey: "nexusCloudClipboardPaths") }
    }
    /// Independent, revocable permission for image CKAsset transfer.
    @Published var includeImages: Bool {
        didSet { defaults.set(includeImages, forKey: "nexusCloudClipboardImages") }
    }
    @Published var includeFiles: Bool {
        didSet { defaults.set(includeFiles, forKey: "nexusCloudClipboardFiles") }
    }
    @Published private(set) var status = "iCloud clipboard sync is off"
    @Published private(set) var nextHistoryOffset: Int
    @Published private(set) var pendingCount = 0
    @Published private(set) var cachedRecords: [ClipboardCloudRecord] = []
    @Published private(set) var running = false
    @Published private(set) var lastSuccessfulSync: ClipboardCloudRunSummary?

    private let defaults: UserDefaults
    private let deviceID: String
    private let journal: ClipboardCloudJournal?
    private let store: OperationStore?
    private let zoneID = CKRecordZone.ID(
        zoneName: "NexusClipboard", ownerName: CKCurrentUserDefaultName
    )
    private let maximumHistoryPage = 200
    private var automaticSyncTimer: Timer?
    private var automaticSyncTask: Task<Void, Never>?
    private var automaticCycleRunning = false

    private init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        lastSuccessfulSync = defaults.data(forKey: "nexusCloudClipboardLastSuccess")
            .flatMap { try? JSONDecoder().decode(ClipboardCloudRunSummary.self, from: $0) }
        enabled = defaults.bool(forKey: "nexusCloudClipboardEnabled")
        automaticSyncEnabled = defaults.bool(forKey: "nexusCloudClipboardAutomaticSync")
        includeNames = defaults.bool(forKey: "nexusCloudClipboardNames")
        includeText = defaults.bool(forKey: "nexusCloudClipboardText")
        includePaths = defaults.bool(forKey: "nexusCloudClipboardPaths")
        includeImages = defaults.bool(forKey: "nexusCloudClipboardImages")
        includeFiles = defaults.bool(forKey: "nexusCloudClipboardFiles")
        nextHistoryOffset = max(0, defaults.integer(forKey: "nexusCloudClipboardHistoryOffset"))
        if let saved = defaults.string(forKey: "nexusCloudClipboardDeviceID"),
           UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            let newID = UUID().uuidString
            deviceID = newID
            defaults.set(newID, forKey: "nexusCloudClipboardDeviceID")
        }
        store = OperationStore.shared()
        if let group = Bundle.main.object(
            forInfoDictionaryKey: SharedSettings.appGroupIdentifierInfoKey
        ) as? String,
           let home = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: group
           ) {
            journal = try? ClipboardCloudJournal(
                url: home.appendingPathComponent("NexusClipboardCloudJournal.sqlite")
            )
        } else {
            journal = nil
        }
        refreshLocalCache()
        configureAutomaticSyncTimer()
    }

    /// The timer is created only under both independent user consents and a
    /// signed CloudKit configuration. A disabled toggle prevents future
    /// network attempts and cancels our scheduled in-flight task.
    private func configureAutomaticSyncTimer() {
        automaticSyncTimer?.invalidate()
        automaticSyncTimer = nil
        guard ClipboardCloudAutomaticSyncPolicy.maySchedule(
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

    var containerConfigured: Bool { configuredContainerID != nil }

    private var configuredContainerID: String? {
        guard let id = Bundle.main.object(
            forInfoDictionaryKey: "NexusCloudKitContainerIdentifier"
        ) as? String, id.hasPrefix("iCloud."), !id.contains("$"),
              id.utf8.count < 200 else { return nil }
        return id
    }

    /// Stages one 200-record page and all local collections in an isolated
    /// utility task; the card UI never waits for SQLite/image work. This is a
    /// local preparatory action, not an implicit CloudKit upload.
    func prepareLocalPage() async {
        guard !running else { return }
        guard enabled else {
            status = "Enable iCloud clipboard consent first"
            return
        }
        guard let store, let journal else {
            status = "Local clipboard or journal database unavailable"
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
            defaults.set(nextHistoryOffset, forKey: "nexusCloudClipboardHistoryOffset")
            refreshLocalCache()
            status = "Prepared \(result.0.staged) history records and \(result.1) collection changes locally"
        } catch {
            status = "Local preparation failed: \(error.localizedDescription)"
        }
    }

    /// This is the ONLY place a CloudKit container may be created. It is
    /// invoked by a direct user click after an explicit account consent.
    func setupPrivateZone() async {
        guard !running else { return }
        guard enabled else { status = "Enable iCloud clipboard consent first"; return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            try await transport.createZoneIfRequested()
            status = "Private iCloud clipboard zone ready"
        } catch {
            status = "iCloud zone unavailable: \(error.localizedDescription)"
        }
    }

    func syncNow(automaticRun: Bool = false) async {
        guard !running else { return }
        guard enabled else { status = "Enable iCloud clipboard consent first"; return }
        if automaticRun && (!automaticSyncEnabled || Task.isCancelled) { return }
        guard let journal else { status = "Cloud journal unavailable"; return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let coordinator = try ClipboardCloudSyncCoordinator(
                journal: journal, transport: transport, zoneID: zoneID.zoneName
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
                    defaults.set(encoded, forKey: "nexusCloudClipboardLastSuccess")
                }
            }
            refreshLocalCache()
            status = "Uploaded \(report.uploaded), received \(report.downloaded), pending \(report.pending)" +
                (report.moreComing ? " — more cloud pages available" : "")
        } catch {
            status = "iCloud clipboard sync failed: \(error.localizedDescription)"
        }
    }

    /// User-invoked recovery from CKError.changeTokenExpired. This restarts
    /// incremental download and preserves local pending updates.
    func resetServerCursor() {
        guard !running, enabled, let journal else { return }
        do {
            try journal.resetChangeToken(forZone: zoneID.zoneName)
            status = "Cloud sync cursor reset. The next manual sync replays the zone."
            refreshLocalCache()
        } catch {
            status = "Could not reset sync cursor: \(error.localizedDescription)"
        }
    }

    /// Explicitly restore sanitized metadata/text from the local CloudKit
    /// journal into the normal history shelf. Never materializes remote file
    /// paths as working local file URL references.
    func restoreCachedHistory() async {
        guard !running, enabled else { return }
        guard let journal, let store else {
            status = "Clipboard history or cloud journal database unavailable"
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
            status = "Remote text copied to system clipboard"
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
            status = localized("Local iCloud clipboard cache cleared; original local history preserved")
        } catch {
            status = localized("Local cloud cache removal failed") + ": "
                + error.localizedDescription
        }
    }

    /// Erases the dedicated NexusClipboard private CloudKit zone ONLY after
    /// a separate typed confirmation in the settings sheet. Sync is disabled
    /// before network access to prevent any new local uploads during cleanup.
    /// If the network fails, the local journal remains available for retry.
    func erasePrivateNexusCloudZone(confirmation: String) async {
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
                    // If local mirror removal fails, preserve CloudKit's
                    // outbox and cursor for a safe, idempotent retry.
                    _ = try store.discardImportedCloudMirrors()
                }
            )
            resetCloudPreferencesAfterPurge()
            refreshLocalCache()
            status = localized("Nexus private iCloud clipboard zone deleted. Disable sync on other devices to prevent recreation.")
        } catch {
            status = localized("Cloud deletion failed; sync remains disabled and local recovery data may remain")
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
        defaults.removeObject(forKey: "nexusCloudClipboardHistoryOffset")
        lastSuccessfulSync = nil
        defaults.removeObject(forKey: "nexusCloudClipboardLastSuccess")
    }

    /// User-triggered local export of a verified CloudKit file asset.
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

    private func makeTransport() async throws -> ClipboardCloudKitPrivateTransport {
        enum Availability: Error { case missingContainer, unavailableAccount }
        guard let id = configuredContainerID else { throw Availability.missingContainer }
        let container = CKContainer(identifier: id)
        guard try await container.accountStatus() == .available else {
            throw Availability.unavailableAccount
        }
        let store = store
        return try ClipboardCloudKitPrivateTransport(
            database: container.privateCloudDatabase, zoneID: zoneID,
            imageProvider: { id in
                guard id.hasPrefix("operation:"),
                      let store, let image = try store.imageContent(
                        operationID: String(id.dropFirst("operation:".count))
                      ) else { return nil }
                return ClipboardCloudImageAsset(
                    bytes: image.data, pasteboardType: image.pasteboardType
                )
            },
            mayDownloadImages: { [weak self] in
                await MainActor.run {
                    self?.currentConsent.includeImages == true
                }
            },
            fileProvider: { id in
                guard id.hasPrefix("operation:"),
                      let store else { return nil }
                return try store.cloudFileAsset(
                    operationID: String(id.dropFirst("operation:".count))
                )
            },
            mayDownloadFiles: { [weak self] in
                await MainActor.run {
                    self?.currentConsent.includeFiles == true
                }
            }
        )
    }
}
