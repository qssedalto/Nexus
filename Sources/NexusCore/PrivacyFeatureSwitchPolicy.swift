import Foundation

/// Single policy used by privacy-facing switches and actual runtime gates.
/// A retained OS permission is not consent to continue observing or uploading.
public enum PrivacyFeatureSwitchPolicy {
    public static func shouldMonitorInput(
        enabled: Bool, paused: Bool, permissionGranted: Bool
    ) -> Bool {
        enabled && !paused && permissionGranted
    }

    public static func shouldUploadStatistics(
        enabled: Bool, automaticRun: Bool, automatic: Bool
    ) -> Bool {
        enabled && (!automaticRun || automatic)
    }
    /// A token removal permanently disables Nexus access, even if Keychain
    /// deletion fails or an older application still owns a valid credential.
    /// Only an explicit successful Nexus token save may clear this revocation.
    public static func shouldReadStoredAPIToken(
        credentialRevoked: Bool,
        isLegacyService: Bool,
        legacyFallbackDisabled: Bool
    ) -> Bool {
        !credentialRevoked && (!isLegacyService || !legacyFallbackDisabled)
    }

}
