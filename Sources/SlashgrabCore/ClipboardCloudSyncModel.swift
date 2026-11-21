import Foundation

/// CloudKit-ready, provider-independent sync records. This file does NOT
/// connect to iCloud, add entitlements, or send clipboard information.
public enum ClipboardCloudKind: String, Codable, Sendable {
    case operation, collection, membership
}

/// Logical revision: no reliance on wall clocks, timezone, or device skew.
/// Each local edit must advance beyond both its local and observed revision.
public struct ClipboardCloudRevision: Codable, Sendable, Equatable {
    public let counter: Int64
    public let deviceID: String

    public init(counter: Int64, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }

    public static func next(
        deviceID: String, after first: ClipboardCloudRevision?,
        observing second: ClipboardCloudRevision? = nil
    ) -> ClipboardCloudRevision? {
        let maximum = max(first?.counter ?? 0, second?.counter ?? 0)
        guard maximum >= 0, maximum < Int64.max,
              !deviceID.isEmpty, deviceID.utf8.count <= 80 else { return nil }
        return ClipboardCloudRevision(counter: maximum + 1, deviceID: deviceID)
    }
}

/// Consent is purpose-specific and ALWAYS disabled by default.
/// Image binary bytes never enter this JSON wire model. A separate,
/// explicitly authorized CKAsset may be referenced by digest and size.
public struct ClipboardCloudConsent: Sendable, Equatable {
    public let enabled: Bool
    public let includeText: Bool
    public let includeNames: Bool
    public let includePaths: Bool
    public let includeImages: Bool
    public let includeFiles: Bool

    public init(enabled: Bool = false, includeText: Bool = false,
                includeNames: Bool = false, includePaths: Bool = false,
                includeImages: Bool = false, includeFiles: Bool = false) {
        self.enabled = enabled
        self.includeText = includeText
        self.includeNames = includeNames
        self.includePaths = includePaths
        self.includeImages = includeImages
        self.includeFiles = includeFiles
    }
}

public struct ClipboardCloudItem: Codable, Sendable, Equatable {
    public let kind: String
    public let size: Int64?
    public let name: String?
    public let path: String?
}

public struct ClipboardCloudOperation: Codable, Sendable, Equatable {
    public let type: String
    public let detectedTimeMS: Int64
    public let sourceApplication: String?
    public let items: [ClipboardCloudItem]
    public let text: String?
    /// Optional digest-only reference. The actual image lives in an
    /// independently consented CloudKit CKAsset, never embedded as JSON.
    public let image: ClipboardCloudImageReference?
    /// A single, independently authorized small regular file can be included
    /// as a CKAsset. No local path or binary bytes enter this JSON reference.
    public let file: ClipboardCloudFileReference?

    /// Build a privacy-minimized snapshot of the user's local record.
    /// File paths, filenames, clipboard bodies and image pixel data are
    /// never included just because the base CloudKit toggle was enabled.
    public init?(record: RecordedOperation, consent: ClipboardCloudConsent,
                 image: ClipboardCloudImageReference? = nil,
                 file: ClipboardCloudFileReference? = nil) {
        guard consent.enabled else { return nil }
        type = record.type
        detectedTimeMS = record.detectedTimeMS
        sourceApplication = record.sourceApplication
        self.image = consent.includeImages && record.type == "image_copy" ? image : nil
        self.file = consent.includeFiles
            && ["copy", "path_copy", "drop_copy"].contains(record.type)
            && record.items.count == 1 ? file : nil
        items = record.items.prefix(200).map {
            ClipboardCloudItem(kind: $0.kind, size: $0.size,
                               name: consent.includeNames ? $0.name : nil,
                               path: consent.includePaths ? $0.source : nil)
        }
        // Keep previews bounded. A large text blob requires an explicitly
        // separate future large-asset transport rather than silent truncation.
        if consent.includeText, let original = record.clipboardText,
           original.utf8.count <= 64 * 1024 {
            text = original
        } else {
            text = nil
        }
    }
}

public struct ClipboardCloudCollection: Codable, Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct ClipboardCloudMembership: Codable, Sendable, Equatable {
    public let collectionID: String
    public let operationID: String
    public let sortPosition: Int64

    public init(collectionID: String, operationID: String, sortPosition: Int64) {
        self.collectionID = collectionID
        self.operationID = operationID
        self.sortPosition = sortPosition
    }
}

public enum ClipboardCloudPayload: Codable, Sendable, Equatable {
    case operation(ClipboardCloudOperation)
    case collection(ClipboardCloudCollection)
    case membership(ClipboardCloudMembership)

    public var kind: ClipboardCloudKind {
        switch self {
        case .operation: return .operation
        case .collection: return .collection
        case .membership: return .membership
        }
    }
}

public enum ClipboardCloudModelError: Error, Sendable, Equatable {
    case invalidRecord, mismatchedKind, conflictingMutation, unsupportedVersion, oversizedBatch
}

/// One stable identity per logical object; delete is a payload-free tombstone.
/// IDs never contain local filesystem paths or clipboard contents.
public struct ClipboardCloudRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ClipboardCloudKind
    public let revision: ClipboardCloudRevision
    public let mutationID: String
    public let isDeleted: Bool
    public let payload: ClipboardCloudPayload?

    public init(
        id: String, kind: ClipboardCloudKind, revision: ClipboardCloudRevision,
        mutationID: String = UUID().uuidString,
        isDeleted: Bool = false, payload: ClipboardCloudPayload?
    ) {
        self.id = id
        self.kind = kind
        self.revision = revision
        self.mutationID = mutationID
        self.isDeleted = isDeleted
        self.payload = payload
    }

    public static func operationID(_ id: String) -> String { "operation:" + id }
    public static func collectionID(_ id: String) -> String { "collection:" + id }
    public static func membershipID(collectionID: String, operationID: String) -> String {
        "membership:" + collectionID + ":" + operationID
    }

    public func validated() throws -> ClipboardCloudRecord {
        let prefix = kind.rawValue + ":"
        guard id.hasPrefix(prefix), id.utf8.count <= 240,
              id.utf8.count > prefix.utf8.count,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              revision.counter >= 0, !revision.deviceID.isEmpty,
              revision.deviceID.utf8.count <= 80,
              UUID(uuidString: mutationID) != nil,
              isDeleted ? payload == nil : payload?.kind == kind else {
            throw ClipboardCloudModelError.invalidRecord
        }
        if case .operation(let operation)? = payload {
            if let image = operation.image {
                guard operation.type == "image_copy", image.isStructurallyValid else {
                    throw ClipboardCloudModelError.invalidRecord
                }
            }
            if let file = operation.file {
                guard ["copy", "path_copy", "drop_copy"].contains(operation.type),
                      operation.items.count == 1, file.isStructurallyValid else {
                    throw ClipboardCloudModelError.invalidRecord
                }
            }
            guard !(operation.image != nil && operation.file != nil) else {
                throw ClipboardCloudModelError.invalidRecord
            }
        }
        return self
    }

    /// A deleted operation never contains or leaks the old body.
    public func tombstone(revision: ClipboardCloudRevision) -> ClipboardCloudRecord {
        ClipboardCloudRecord(id: id, kind: kind, revision: revision,
                             isDeleted: true, payload: nil)
    }
}

public struct ClipboardCloudBatch: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sendingDeviceID: String
    public let changes: [ClipboardCloudRecord]

    public init(sendingDeviceID: String, changes: [ClipboardCloudRecord]) {
        schemaVersion = 1
        self.sendingDeviceID = sendingDeviceID
        self.changes = changes
    }

    public func validated() throws -> ClipboardCloudBatch {
        guard schemaVersion == 1 else { throw ClipboardCloudModelError.unsupportedVersion }
        guard !sendingDeviceID.isEmpty, sendingDeviceID.utf8.count <= 80,
              changes.count <= 200 else { throw ClipboardCloudModelError.oversizedBatch }
        for change in changes { _ = try change.validated() }
        return self
    }
}

/// Deterministic, retry-safe merge for CloudKit record changes, independent of
/// incoming page/order. A tombstone wins equal logical counters to prevent a
/// stale update resurrecting an entry; higher counters represent later edits.
/// Deletion history must be retained until all participating devices catch up.
public enum ClipboardCloudMerge {
    public static func winner(
        _ existing: ClipboardCloudRecord, _ incoming: ClipboardCloudRecord
    ) throws -> ClipboardCloudRecord {
        _ = try existing.validated()
        _ = try incoming.validated()
        guard existing.id == incoming.id, existing.kind == incoming.kind else {
            throw ClipboardCloudModelError.mismatchedKind
        }
        if existing.revision.counter != incoming.revision.counter {
            return existing.revision.counter > incoming.revision.counter ? existing : incoming
        }
        if existing.isDeleted != incoming.isDeleted {
            return existing.isDeleted ? existing : incoming
        }
        if existing.revision.deviceID != incoming.revision.deviceID {
            return existing.revision.deviceID > incoming.revision.deviceID ? existing : incoming
        }
        if existing.mutationID != incoming.mutationID {
            return existing.mutationID > incoming.mutationID ? existing : incoming
        }
        guard existing == incoming else {
            throw ClipboardCloudModelError.conflictingMutation
        }
        return existing
    }

    public static func merged(
        existing: [ClipboardCloudRecord], incoming: [ClipboardCloudRecord]
    ) throws -> [ClipboardCloudRecord] {
        var latest: [String: ClipboardCloudRecord] = [:]
        for record in existing + incoming {
            _ = try record.validated()
            if let old = latest[record.id] {
                latest[record.id] = try winner(old, record)
            } else {
                latest[record.id] = record
            }
        }
        return latest.values.sorted { $0.id < $1.id }
    }
}
