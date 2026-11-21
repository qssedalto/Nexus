import CloudKit
import Foundation

/// A real CKDatabase-backed adapter, but deliberately never instantiated by
/// the production app until a signed CloudKit container, account and explicit
/// user authorization are provided. No silent iCloud activity or default zone
/// creation occurs in the initializer.
public actor ClipboardCloudKitPrivateTransport: ClipboardCloudTransport, ClipboardCloudPrivateZoneDeletion {
    public enum TransportError: Error {
        case privateDatabaseRequired, invalidZone, oversizedBatch
        case unexpectedPhysicalDeletion, malformedChangeToken, returnedRecordMismatch
        case remoteRevisionRequiresReconciliation
        case missingOrCorruptImageAsset
    }

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let imageProvider: @Sendable (String) async throws -> ClipboardCloudImageAsset?
    private let mayDownloadImages: @Sendable () async -> Bool

    public init(
        database: CKDatabase, zoneID: CKRecordZone.ID,
        imageProvider: @escaping @Sendable (String) async throws -> ClipboardCloudImageAsset? = { _ in nil },
        mayDownloadImages: @escaping @Sendable () async -> Bool = { false }
    ) throws {
        guard database.databaseScope == .private else {
            throw TransportError.privateDatabaseRequired
        }
        guard !zoneID.zoneName.isEmpty, zoneID.zoneName.utf8.count <= 255 else {
            throw TransportError.invalidZone
        }
        self.database = database
        self.zoneID = zoneID
        self.imageProvider = imageProvider
        self.mayDownloadImages = mayDownloadImages
    }

    /// Explicit setup step; never run on app launch. Apple requires a saved
    /// private custom zone before operations can target its records.
    public func createZoneIfRequested() async throws {
        let result = try await database.recordZones(for: [zoneID])
        if let existing = result[zoneID] {
            switch existing {
            case .success: return
            case .failure(let error):
                guard let cloudError = error as? CKError,
                      cloudError.code == .zoneNotFound else { throw error }
            }
        }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }

    /// Destructive, explicit-only operation for the dedicated NexusClipboard
    /// private zone. Caller must show a separate confirmation and disable
    /// further local sync before invoking. Never used by normal sync calls.
    /// A zone already absent is treated as successfully erased to permit
    /// crash recovery when the remote deletion succeeded but local cleanup did
    /// not complete.
    public func deletePrivateNexusZone() async throws {
        guard zoneID.zoneName == "NexusClipboard" else {
            throw TransportError.invalidZone
        }
        do {
            _ = try await database.deleteRecordZone(withID: zoneID)
        } catch {
            if let ckError = error as? CKError, ckError.code == .zoneNotFound {
                return
            }
            throw error
        }
    }

    /// Conflict-safe write of a bounded page. For an existing CKRecord we
    /// first merge the remote and local logical revisions, then write using
    /// that server record's change tag; a concurrent overwrite fails rather
    /// than erasing another Mac's newer edit or deletion tombstone.
    public func upload(
        _ changes: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck] {
        guard changes.count <= 100 else { throw TransportError.oversizedBatch }
        var acknowledged: [ClipboardCloudUploadAck] = []
        for change in changes {
            try Task.checkCancellation()
            _ = try change.validated()
            guard await permissionCheck(change) else {
                throw ClipboardCloudSyncError.consentRequired
            }
            let id = CKRecord.ID(recordName: change.id, zoneID: zoneID)
            let existing: CKRecord?
            do {
                existing = try await database.record(for: id)
            } catch {
                if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                    existing = nil
                } else {
                    throw error
                }
            }

            if let existing {
                let server = try ClipboardCloudKitCodec.decode(
                    existing, expectedZoneID: zoneID
                )
                switch try ClipboardCloudUploadDecision.decide(
                    local: change, server: server
                ) {
                case .acknowledgeExactRetry:
                    acknowledged.append(ClipboardCloudUploadAck(
                        id: change.id, mutationID: change.mutationID
                    ))
                    continue
                case .requiresRemoteReconciliation:
                    // Do not falsely acknowledge or drop the local mutation:
                    // the winning server content must first reach the journal.
                    throw TransportError.remoteRevisionRequiresReconciliation
                case .uploadNewVersion:
                    break
                }
                let (encoded, assetFile) = try await encodeWithImageAsset(change)
                defer { if let assetFile { try? FileManager.default.removeItem(at: assetFile) } }
                for key in ["schemaVersion", "kind", "counter", "deviceID",
                            "mutationID", "isDeleted", "document", "imageAsset"] {
                    existing[key] = encoded[key]
                }
                // The server version lookup is itself an awaited network
                // request. Preferences may have changed while it completed.
                guard await permissionCheck(change) else {
                    throw ClipboardCloudSyncError.consentRequired
                }
                try Task.checkCancellation()
                let saved = try await database.save(existing)
                let received = try ClipboardCloudKitCodec.decode(
                    saved, expectedZoneID: zoneID
                )
                guard received == change else {
                    throw TransportError.returnedRecordMismatch
                }
            } else {
                let (candidate, assetFile) = try await encodeWithImageAsset(change)
                defer { if let assetFile { try? FileManager.default.removeItem(at: assetFile) } }
                guard await permissionCheck(change) else {
                    throw ClipboardCloudSyncError.consentRequired
                }
                try Task.checkCancellation()
                let saved = try await database.save(candidate)
                let received = try ClipboardCloudKitCodec.decode(
                    saved, expectedZoneID: zoneID
                )
                guard received == change else {
                    throw TransportError.returnedRecordMismatch
                }
            }
            acknowledged.append(ClipboardCloudUploadAck(
                id: change.id, mutationID: change.mutationID
            ))
        }
        return acknowledged
    }

    /// Create temporary CKAsset content only after an authorized image upload
    /// is selected. The file exists until CKDatabase.save completes and is
    /// removed whether the network succeeds or fails.
    private func encodeWithImageAsset(
        _ change: ClipboardCloudRecord
    ) async throws -> (CKRecord, URL?) {
        let record = try ClipboardCloudKitCodec.encode(change, zoneID: zoneID)
        guard case .operation(let info)? = change.payload,
              let reference = info.image else { return (record, nil) }
        guard let image = try await imageProvider(change.id),
              image.matches(reference) else {
            throw TransportError.missingOrCorruptImageAsset
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-cloud-" + UUID().uuidString)
        try image.bytes.write(to: destination, options: .atomic)
        record["imageAsset"] = CKAsset(fileURL: destination)
        return (record, destination)
    }

    /// Incremental download of one server page. Physically removed CKRecords
    /// are intentionally rejected: Nexus uses durable, payload-free logical
    /// tombstones instead, to prevent stale devices resurrecting deletions.
    /// A malformed individual record fails the entire page and its token is
    /// never advanced by the higher-level coordinator.
    public func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage {
        let previous: CKServerChangeToken?
        if let token {
            do {
                previous = try NSKeyedUnarchiver.unarchivedObject(
                    ofClass: CKServerChangeToken.self, from: token
                )
            } catch {
                throw TransportError.malformedChangeToken
            }
            guard previous != nil else { throw TransportError.malformedChangeToken }
        } else {
            previous = nil
        }
        let imageDownloadAllowed = await mayDownloadImages()
        let baseKeys = ["schemaVersion", "kind", "counter", "deviceID",
                        "mutationID", "isDeleted", "document"]
        let page = try await database.recordZoneChanges(
            inZoneWith: zoneID, since: previous,
            desiredKeys: imageDownloadAllowed ? nil : baseKeys, resultsLimit: 200
        )
        guard page.deletions.isEmpty else {
            throw TransportError.unexpectedPhysicalDeletion
        }
        var changes: [ClipboardCloudRecord] = []
        var images: [String: ClipboardCloudImageAsset] = [:]
        for result in page.modificationResultsByID.values {
            switch result {
            case .success(let modification):
                let cloudRecord = modification.record
                let decoded = try ClipboardCloudKitCodec.decode(
                    cloudRecord, expectedZoneID: zoneID
                )
                if case .operation(let operation)? = decoded.payload,
                   let reference = operation.image {
                    // Never load image bytes after the user revoked consent,
                    // even if an in-flight server response carries an asset.
                    guard imageDownloadAllowed, await mayDownloadImages(),
                          let asset = cloudRecord["imageAsset"] as? CKAsset,
                          let source = asset.fileURL, source.isFileURL else {
                        throw ClipboardCloudSyncError.consentRequired
                    }
                    let values = try source.resourceValues(forKeys: [
                        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
                    ])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          let size = values.fileSize, size == reference.byteCount,
                          size > 0, size <= ClipboardCloudImageReference.maximumBytes,
                          let image = ClipboardCloudImageAsset(
                            bytes: try Data(contentsOf: source, options: .mappedIfSafe),
                            pasteboardType: reference.pasteboardType
                          ),
                          image.matches(reference) else {
                        throw TransportError.missingOrCorruptImageAsset
                    }
                    images[decoded.id] = image
                }
                changes.append(decoded)
            case .failure(let error):
                throw error
            }
        }
        let checkpoint = try NSKeyedArchiver.archivedData(
            withRootObject: page.changeToken, requiringSecureCoding: true
        )
        return ClipboardCloudDownloadPage(
            changes: changes, token: checkpoint,
            moreComing: page.moreComing, imageAssets: images
        )
    }
}
