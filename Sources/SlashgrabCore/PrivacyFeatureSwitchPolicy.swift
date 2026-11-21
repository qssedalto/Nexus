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
}
