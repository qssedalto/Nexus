import CloudKit
import Foundation
import NexusMobileCore
import SwiftUI
import UIKit

/// Universal iOS/iPadOS client. iOS cannot passively monitor another app's
/// clipboard, so text is read ONLY on a direct button press in the foreground.
@MainActor
final class MobileClipboardController: ObservableObject {
    @Published var cloudEnabled: Bool {
        didSet { defaults.set(cloudEnabled, forKey: "nexusMobileCloudEnabled") }
    }
    @Published var includeText: Bool {
        didSet { defaults.set(includeText, forKey: "nexusMobileCloudText") }
    }
    @Published var includeNames: Bool {
        didSet { defaults.set(includeNames, forKey: "nexusMobileCloudNames") }
    }
    @Published var includePaths: Bool {
        didSet { defaults.set(includePaths, forKey: "nexusMobileCloudPaths") }
    }
    @Published private(set) var records: [ClipboardCloudRecord] = []
    @Published private(set) var localEntries: [MobileLocalClipboardEntry] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var status = NSLocalizedString("No cloud network activity until you press Sync", comment: "")
    @Published private(set) var running = false
    @Published private(set) var lastSuccessfulSync: ClipboardCloudRunSummary?

    private let defaults: UserDefaults
    private let journal: ClipboardCloudJournal?
    private let localStore: MobileClipboardLocalStore?
    private let deviceID: String
    private let zoneID = CKRecordZone.ID(
        zoneName: "NexusClipboard", ownerName: CKCurrentUserDefaultName
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastSuccessfulSync = defaults.data(forKey: "nexusMobileCloudLastSuccess")
            .flatMap { try? JSONDecoder().decode(ClipboardCloudRunSummary.self, from: $0) }
        cloudEnabled = defaults.bool(forKey: "nexusMobileCloudEnabled")
        includeText = defaults.bool(forKey: "nexusMobileCloudText")
        includeNames = defaults.bool(forKey: "nexusMobileCloudNames")
        includePaths = defaults.bool(forKey: "nexusMobileCloudPaths")
        if let existing = defaults.string(forKey: "nexusMobileCloudDeviceID"),
           UUID(uuidString: existing) != nil {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: "nexusMobileCloudDeviceID")
            deviceID = generated
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            journal = try? ClipboardCloudJournal(
                url: support.appendingPathComponent("NexusMobileCloudJournal.sqlite")
            )
            localStore = try? MobileClipboardLocalStore(
                url: support.appendingPathComponent("NexusMobileLocalHistory.sqlite")
            )
        } else {
            journal = nil
            localStore = nil
        }
        refresh()
    }

    var containerConfigured: Bool { containerID != nil }

    private var containerID: String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "NexusCloudKitContainerIdentifier"
        ) as? String, value.hasPrefix("iCloud."), !value.contains("$"),
              value.utf8.count <= 200 else { return nil }
        return value
    }

    private var consent: ClipboardCloudConsent {
        ClipboardCloudConsent(
            enabled: cloudEnabled, includeText: includeText,
            includeNames: includeNames, includePaths: includePaths
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
            // CloudKit consent. CloudKit staging requires explicit opt-in.
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

    func setupPrivateZone() async {
        guard !running, cloudEnabled else { return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            try await transport.createZoneIfRequested()
            status = NSLocalizedString("iCloud private zone ready", comment: "")
        } catch {
            status = "iCloud setup unavailable: \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard !running, cloudEnabled, let journal else { return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let coordinator = try ClipboardCloudSyncCoordinator(
                journal: journal, transport: transport, zoneID: zoneID.zoneName
            )
            let report = try await coordinator.syncOnce(consentProvider: { [weak self] in
                await MainActor.run {
                    self?.consent ?? ClipboardCloudConsent()
                }
            })
            if let summary = ClipboardCloudRunSummary(
                report: report,
                finishedTimeMS: Int64(Date().timeIntervalSince1970 * 1_000)
            ) {
                lastSuccessfulSync = summary
                if let encoded = try? JSONEncoder().encode(summary) {
                    defaults.set(encoded, forKey: "nexusMobileCloudLastSuccess")
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
            try journal.resetChangeToken(forZone: zoneID.zoneName)
            status = NSLocalizedString("Sync cursor reset; next sync replays remote changes", comment: "")
            refresh()
        } catch {
            status = "Cannot reset cursor: \(error.localizedDescription)"
        }
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

    /// Explicit offline-only removal of CloudKit cache/outbox/cursors.
    /// The separately saved iPhone/iPad local clipboard history is retained.
    func clearLocalCloudData() async {
        guard !running, let journal else { return }
        cloudEnabled = false
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
    func erasePrivateNexusCloudZone() async {
        guard !running, let journal else { return }
        cloudEnabled = false
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            let purge = ClipboardCloudPurgeCoordinator(
                transport: transport, journal: journal
            )
            try await purge.purgeCloudZoneAndLocalCache(
                explicitlyConfirmed: true
            )
            resetCloudPreferencesAfterPurge()
            refresh()
            status = NSLocalizedString(
                "Nexus iCloud zone deleted. Disable syncing on other devices.",
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
        lastSuccessfulSync = nil
        defaults.removeObject(forKey: "nexusMobileCloudLastSuccess")
    }

    private func makeTransport() async throws -> ClipboardCloudKitPrivateTransport {
        enum Unavailable: Error { case missingContainer, signedOut }
        guard let id = containerID else { throw Unavailable.missingContainer }
        let container = CKContainer(identifier: id)
        guard try await container.accountStatus() == .available else {
            throw Unavailable.signedOut
        }
        return try ClipboardCloudKitPrivateTransport(
            database: container.privateCloudDatabase, zoneID: zoneID
        )
    }
}
