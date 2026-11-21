import Foundation

/// Prepares only pre-existing local clipboard history for an explicitly
/// requested future CloudKit sync. No network, polling or background timers.
public enum ClipboardCloudLocalSnapshot {
    public struct Result: Sendable, Equatable {
        public let inspected: Int
        public let staged: Int
        public let nextOffset: Int?
    }

    public static func stagePage(
        from store: OperationStore,
        in journal: ClipboardCloudJournal,
        deviceID: String,
        consent: ClipboardCloudConsent,
        offset: Int = 0,
        limit: Int = 100
    ) throws -> Result {
        guard consent.enabled, !deviceID.isEmpty,
              deviceID.utf8.count <= 80 else {
            return Result(inspected: 0, staged: 0, nextOffset: nil)
        }
        let count = max(1, min(200, limit))
        let history = try store.cloudEligibleHistoryPage(offset: offset, limit: count)
        var staged = 0
        for record in history {
            // Large image bytes are only loaded from the separate original
            // image table after the user opts into CloudKit image transfer.
            let imageReference: ClipboardCloudImageReference?
            if consent.includeImages && record.type == "image_copy",
               let content = try store.imageContent(operationID: record.id) {
                imageReference = ClipboardCloudImageReference(
                    bytes: content.data, pasteboardType: content.pasteboardType
                )
            } else {
                imageReference = nil
            }
            let fileReference: ClipboardCloudFileReference?
            if consent.includeFiles && record.items.count == 1,
               ["copy", "path_copy", "drop_copy"].contains(record.type) {
                fileReference = (try? store.cloudFileAsset(
                    operationID: record.id
                ))?.reference
            } else {
                fileReference = nil
            }
            guard let payload = ClipboardCloudOperation(
                record: record, consent: consent, image: imageReference,
                file: fileReference
            ) else { continue }
            let id = ClipboardCloudRecord.operationID(record.id)
            let previous = try journal.record(id: id)
            let desired = ClipboardCloudPayload.operation(payload)
            if previous?.isDeleted == false && previous?.payload == desired {
                continue
            }
            guard let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: previous?.revision
            ) else { continue }
            let changed = ClipboardCloudRecord(
                id: id, kind: .operation, revision: revision, payload: desired
            )
            if try journal.stageLocal(changed) { staged += 1 }
        }
        return Result(inspected: history.count, staged: staged,
                      nextOffset: history.count == count ? offset + history.count : nil)
    }

    public static func stageCollections(
        from store: OperationStore,
        in journal: ClipboardCloudJournal,
        deviceID: String,
        consent: ClipboardCloudConsent
    ) throws -> Int {
        guard consent.enabled, !deviceID.isEmpty,
              deviceID.utf8.count <= 80 else { return 0 }
        var count = 0
        for collection in try store.listCollections()
            where !collection.id.hasPrefix("cloudkit:") {
            // Imported remote mirrors must never be staged back to CloudKit.
            // Custom collection names require independent content consent.
            if consent.includeNames {
                count += try stage(
                    id: ClipboardCloudRecord.collectionID(collection.id),
                    kind: .collection,
                    payload: .collection(ClipboardCloudCollection(name: collection.name)),
                    journal: journal, deviceID: deviceID
                )
            }
            let entries = try store.collectionOperationIDs(collectionID: collection.id)
            // Membership IDs are only useful if collection names were
            // authorized too. Never leak opaque membership links otherwise.
            guard consent.includeNames else { continue }
            for (index, operationID) in entries.prefix(2_000).enumerated() {
                count += try stage(
                    id: ClipboardCloudRecord.membershipID(
                        collectionID: collection.id, operationID: operationID),
                    kind: .membership,
                    payload: .membership(ClipboardCloudMembership(
                        collectionID: collection.id, operationID: operationID,
                        sortPosition: Int64(index))),
                    journal: journal, deviceID: deviceID
                )
            }
        }
        return count
    }

    /// Caller invokes only AFTER a local deletion succeeds; requires an
    /// already-staged local operation and explicit consent. A tombstone
    /// carries no old text/path/name even if consent has since narrowed.
    @discardableResult
    public static func stageDeletion(
        localOperationID: String,
        in journal: ClipboardCloudJournal,
        deviceID: String,
        consent: ClipboardCloudConsent
    ) throws -> Bool {
        guard consent.enabled, let previous = try journal.record(
            id: ClipboardCloudRecord.operationID(localOperationID)
        ), !previous.isDeleted,
              let revision = ClipboardCloudRevision.next(
                deviceID: deviceID, after: previous.revision
              ) else { return false }
        return try journal.stageLocal(previous.tombstone(revision: revision))
    }

    private static func stage(
        id: String, kind: ClipboardCloudKind, payload: ClipboardCloudPayload,
        journal: ClipboardCloudJournal, deviceID: String
    ) throws -> Int {
        let previous = try journal.record(id: id)
        if previous?.isDeleted == false && previous?.payload == payload {
            return 0
        }
        guard let revision = ClipboardCloudRevision.next(
            deviceID: deviceID, after: previous?.revision
        ) else { return 0 }
        let next = ClipboardCloudRecord(
            id: id, kind: kind, revision: revision, payload: payload
        )
        return try journal.stageLocal(next) ? 1 : 0
    }
}
