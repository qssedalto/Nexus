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
    @Published private(set) var pendingCount = 0
    @Published private(set) var status = "No cloud network activity until you press Sync"
    @Published private(set) var running = false
    @Published private(set) var lastSuccessfulSync: ClipboardCloudRunSummary?

    private let defaults: UserDefaults
    private let journal: ClipboardCloudJournal?
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
        } else {
            journal = nil
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
        guard let journal else { status = "Local database unavailable"; return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            status = "The clipboard contains no text"
            return
        }
        guard text.utf8.count <= 64 * 1024 else {
            status = "Copied text is above the 64 KB content safety limit"
            return
        }
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        let local = RecordedOperation(detectedTimeMS: stamp, clipboardText: text)
        // Local privacy is independent of network consent. Without CloudKit
        // permission this button does not store content in a sync journal.
        guard cloudEnabled,
              let payload = ClipboardCloudOperation(record: local, consent: consent),
              let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: nil
              ) else {
            status = "Enable iCloud consent before saving this entry for sync"
            return
        }
        let record = ClipboardCloudRecord(
            id: ClipboardCloudRecord.operationID(local.id),
            kind: .operation, revision: revision, payload: .operation(payload)
        )
        do {
            try journal.stageLocal(record)
            refresh()
            status = "Clipboard entry saved to local sync queue"
        } catch {
            status = "Could not save clipboard entry: \(error.localizedDescription)"
        }
    }

    func createCollection(named proposed: String) {
        guard cloudEnabled, includeNames, let journal else {
            status = "Allow collection names before saving a collection"
            return
        }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 50 else {
            status = "Collection name must contain 1–50 characters"
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
            status = "Permanent collection staged locally"
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
            status = "Added to permanent collection"
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
            status = "Deleted locally; tombstone queued for next sync"
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    func copyText(_ record: ClipboardCloudRecord) {
        guard !record.isDeleted,
              case .operation(let op)? = record.payload,
              let body = op.text, includeText else { return }
        UIPasteboard.general.string = body
        status = "Text copied to system clipboard"
    }

    func setupPrivateZone() async {
        guard !running, cloudEnabled else { return }
        running = true
        defer { running = false }
        do {
            let transport = try await makeTransport()
            try await transport.createZoneIfRequested()
            status = "iCloud private zone ready"
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
            let report = try await coordinator.syncOnce(consent: consent)
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
            status = "Sync cursor reset; next sync replays remote changes"
            refresh()
        } catch {
            status = "Cannot reset cursor: \(error.localizedDescription)"
        }
    }

    func refresh() {
        guard let journal else { return }
        do {
            records = try journal.cachedRecords(limit: 200)
            pendingCount = try journal.pendingCount()
        } catch {
            status = "Could not load local cache: \(error.localizedDescription)"
        }
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
