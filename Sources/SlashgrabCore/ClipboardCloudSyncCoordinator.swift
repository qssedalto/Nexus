import Foundation

/// An acknowledgement must identify the exact mutation. A matching record ID
/// alone is not enough when a user edits an entry during an in-flight upload.
public struct ClipboardCloudUploadAck: Sendable, Hashable {
    public let id: String
    public let mutationID: String

    public init(id: String, mutationID: String) {
        self.id = id
        self.mutationID = mutationID
    }
}

public struct ClipboardCloudDownloadPage: Sendable {
    public let changes: [ClipboardCloudRecord]
    public let token: Data?
    public let moreComing: Bool
    /// Independently authorized binary image assets keyed by operation ID.
    /// These are saved alongside journal records and cursor atomically.
    public let imageAssets: [String: ClipboardCloudImageAsset]

    public init(changes: [ClipboardCloudRecord], token: Data?,
                moreComing: Bool = false,
                imageAssets: [String: ClipboardCloudImageAsset] = [:]) {
        self.changes = changes
        self.token = token
        self.moreComing = moreComing
        self.imageAssets = imageAssets
    }
}

/// Testable adapter seam. The eventual CKDatabase implementation must use a
/// user's private zone, authenticate via supported Apple APIs, and provide
/// bounded, idempotent upload acknowledgements and incremental pages.
public protocol ClipboardCloudTransport: Sendable {
    /// Transport must re-check a dynamic current authorization before every
    /// separate server write, including after any intervening awaited reads.
    func upload(
        _ records: [ClipboardCloudRecord],
        permissionCheck: @escaping @Sendable (ClipboardCloudRecord) async -> Bool
    ) async throws -> [ClipboardCloudUploadAck]
    func fetch(after token: Data?) async throws -> ClipboardCloudDownloadPage
}

public enum ClipboardCloudSyncError: Error, Sendable {
    case invalidZone, consentRequired, unauthorizedContents
    case unexpectedAcknowledgement, oversizedPage
}

public struct ClipboardCloudSyncReport: Sendable, Equatable {
    public let enabled: Bool
    public let uploaded: Int
    public let downloaded: Int
    public let pending: Int
    public let moreComing: Bool

    public static let disabled = ClipboardCloudSyncReport(
        enabled: false, uploaded: 0, downloaded: 0, pending: 0, moreComing: false
    )
}

public extension ClipboardCloudConsent {
    /// Recheck current privacy preferences immediately before both outgoing
    /// and incoming work. A queued record created under old, broader consent
    /// must NOT be silently uploaded after permissions are narrowed.
    func permits(_ record: ClipboardCloudRecord) -> Bool {
        guard enabled else { return false }
        guard !record.isDeleted else { return record.payload == nil }
        guard let payload = record.payload else { return false }
        switch payload {
        case .operation(let operation):
            if !includeText && operation.text != nil { return false }
            if !includeImages && operation.image != nil { return false }
            for item in operation.items {
                if !includeNames && item.name != nil { return false }
                if !includePaths && item.path != nil { return false }
            }
            return true
        case .collection:
            // A user-defined collection name is itself potentially private.
            return includeNames
        case .membership:
            return true
        }
    }
}

/// Serializes one explicit sync attempt. There are no timers, background
/// uploads or CloudKit account accesses in this type. Privacy defaults off;
/// the caller must present a current, explicit consent for every attempt.
public actor ClipboardCloudSyncCoordinator {
    private let journal: ClipboardCloudJournal
    private let transport: any ClipboardCloudTransport
    private let zoneID: String

    public init(journal: ClipboardCloudJournal, transport: any ClipboardCloudTransport,
                zoneID: String) throws {
        guard !zoneID.isEmpty, zoneID.utf8.count <= 180 else {
            throw ClipboardCloudSyncError.invalidZone
        }
        self.journal = journal
        self.transport = transport
        self.zoneID = zoneID
    }

    /// Compatibility entrypoint for offline tests and fixed-consent callers.
    /// Native user-facing clients should use the provider form below so
    /// changes made while awaiting the network are respected.
    public func syncOnce(
        consent: ClipboardCloudConsent
    ) async throws -> ClipboardCloudSyncReport {
        try await syncOnce(consentProvider: { consent })
    }

    /// A single bounded pass: fetch, validate and merge the remote page
    /// BEFORE uploading only after the backlog is drained. Re-read current
    /// authorization after every network suspension and directly before
    /// starting the outbound batch; the transport also verifies authorization
    /// immediately before each separate CloudKit write. A request already
    /// submitted to Apple cannot be unsent, but revocation prevents later
    /// individual server writes and local remote-data import.
    public func syncOnce(
        consentProvider: @escaping @Sendable () async -> ClipboardCloudConsent
    ) async throws -> ClipboardCloudSyncReport {
        let initial = await consentProvider()
        guard initial.enabled else { return .disabled }

        // Verify queued outbound consent before making any network call.
        // A permission revocation must not accidentally upload stale bodies.
        let queued = try journal.pending(limit: 100)
        guard queued.allSatisfy({ initial.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }

        // Fetch first to reconcile stale local logical revisions. Never
        // upload until all incremental pages have reached this Mac.
        let token = try journal.token(forZone: zoneID)
        let page = try await transport.fetch(after: token)
        try Task.checkCancellation()
        // The user may have toggled off sync or individual content categories
        // while waiting for CloudKit. Never import private content after a
        // revocation; leave the prior change token so replay is safe.
        let afterFetch = await consentProvider()
        guard afterFetch.enabled else {
            throw ClipboardCloudSyncError.consentRequired
        }
        guard page.changes.count <= 200 else {
            throw ClipboardCloudSyncError.oversizedPage
        }
        guard page.changes.allSatisfy({ afterFetch.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }
        let downloaded = try journal.applyRemote(
            page.changes, zoneID: zoneID, changeToken: page.token,
            imageAssets: page.imageAssets
        )
        if page.moreComing {
            return ClipboardCloudSyncReport(
                enabled: true, uploaded: 0, downloaded: downloaded,
                pending: try journal.pendingCount(), moreComing: true
            )
        }

        let pending = try journal.pending(limit: 100)
        let beforeUpload = await consentProvider()
        guard beforeUpload.enabled else {
            throw ClipboardCloudSyncError.consentRequired
        }
        guard pending.allSatisfy({ beforeUpload.permits($0) }) else {
            throw ClipboardCloudSyncError.unauthorizedContents
        }
        let acknowledgements: [ClipboardCloudUploadAck]
        if pending.isEmpty {
            acknowledgements = []
        } else {
            acknowledgements = try await transport.upload(
                pending, permissionCheck: { record in
                    let live = await consentProvider()
                    return live.permits(record)
                }
            )
        }
        let expected = Set(pending.map {
            ClipboardCloudUploadAck(id: $0.id, mutationID: $0.mutationID)
        })
        guard acknowledgements.allSatisfy({ expected.contains($0) }) else {
            throw ClipboardCloudSyncError.unexpectedAcknowledgement
        }
        var uploaded = 0
        for acknowledgement in Set(acknowledgements) {
            if try journal.acknowledgeUploaded(
                id: acknowledgement.id,
                mutationID: acknowledgement.mutationID
            ) {
                uploaded += 1
            }
        }
        return ClipboardCloudSyncReport(
            enabled: true, uploaded: uploaded, downloaded: downloaded,
            pending: try journal.pendingCount(), moreComing: false
        )
    }
}
