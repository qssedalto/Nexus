import Foundation

/// A purposely separate destructive capability. Normal sync transports do not
/// need permission to remove a whole CloudKit zone.
public protocol ClipboardCloudPrivateZoneDeletion: Sendable {
    func deletePrivateNexusZone() async throws
}

public enum ClipboardCloudPurgeError: Error, Sendable {
    case explicitConfirmationRequired
}

/// An explicitly initiated privacy operation. Local cached cloud data is NOT
/// discarded until the remote deletion succeeded (or the zone was already
/// absent); a network failure leaves the queue/cursor available for retry.
/// This never deletes the user's independent local clipboard history.
public actor ClipboardCloudPurgeCoordinator {
    private let transport: any ClipboardCloudPrivateZoneDeletion
    private let journal: ClipboardCloudJournal

    public init(
        transport: any ClipboardCloudPrivateZoneDeletion,
        journal: ClipboardCloudJournal
    ) {
        self.transport = transport
        self.journal = journal
    }

    public func purgeCloudZoneAndLocalCache(
        confirmation: String = "",
        afterRemoteDeletion: @Sendable () async throws -> Void = {}
    ) async throws {
        // A boolean from a controller can be passed as 'true' without
        // checking whether the user typed the destructive confirmation.
        // Require the exact confirmation text again at the deletion boundary.
        guard confirmation == "DELETE" else {
            throw ClipboardCloudPurgeError.explicitConfirmationRequired
        }
        try await transport.deletePrivateNexusZone()
        // Keep the outbox and cursor until additional local mirror cleanup
        // completes successfully. An interrupted local step can be retried.
        try await afterRemoteDeletion()
        try journal.discardAllLocalCloudData()
    }
}
