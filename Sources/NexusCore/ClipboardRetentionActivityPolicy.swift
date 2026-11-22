import Foundation

/// Clipboard observation and expiry are independent privacy controls.
/// Pausing capture must not preserve previously saved history indefinitely.
public enum ClipboardRetentionActivityPolicy {
    public static func shouldObserve(
        paused: Bool, files: Bool, text: Bool, images: Bool,
        historyEnabled: Bool = true,
        mirrorEnabled: Bool = false,
        mirrorFiles: Bool = false,
        mirrorText: Bool = false,
        mirrorImages: Bool = false
    ) -> Bool {
        !paused && (
            (historyEnabled && (files || text || images)) ||
            (mirrorEnabled && (mirrorFiles || mirrorText || mirrorImages))
        )
    }

    public static func shouldRunCleanup(
        retentionDays: Int, maximumHistoryRecords: Int
    ) -> Bool {
        retentionDays > 0 || maximumHistoryRecords > 0
    }
}


/// A visible folder mirror is different from an encrypted journal. It does
/// not need a cryptographic pairing key, and never grants journal consent.
public enum ClipboardFolderSyncActivationPolicy {
    public enum Mode: Equatable {
        case unavailable, mirrorOnly, encryptedJournal
    }

    public static func mode(
        folderSelected: Bool, wantsJournal: Bool,
        wantsMirror: Bool, pairingKeyConfigured: Bool
    ) -> Mode {
        guard folderSelected else { return .unavailable }
        if wantsJournal {
            return pairingKeyConfigured ? .encryptedJournal : .unavailable
        }
        return wantsMirror ? .mirrorOnly : .unavailable
    }
}
