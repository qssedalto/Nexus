import Foundation

/// Safe interpretation of the server version before any CloudKit write.
/// An older local change must never be called "uploaded" simply because
/// a different, newer server mutation occupies the same CKRecord ID.
public enum ClipboardCloudUploadDecision: Equatable, Sendable {
    case uploadNewVersion
    case acknowledgeExactRetry
    case requiresRemoteReconciliation

    public static func decide(
        local: ClipboardCloudRecord, server: ClipboardCloudRecord
    ) throws -> ClipboardCloudUploadDecision {
        let winner = try ClipboardCloudMerge.winner(server, local)
        if server == local { return .acknowledgeExactRetry }
        if winner == local { return .uploadNewVersion }
        return .requiresRemoteReconciliation
    }
}
