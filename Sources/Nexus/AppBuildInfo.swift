import Foundation

struct AppBuildInfo: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let variant: String?

    var isDevBuild: Bool {
        if variant?.localizedCaseInsensitiveCompare("dev") == .orderedSame {
            return true
        }

        return bundleIdentifier.hasSuffix(".dev")
            || displayName.localizedCaseInsensitiveContains("dev")
    }

    /// Preview and provisioned CloudKit builds keep a separate bundle ID
    /// without displaying a developer-only badge to users.
    var isCloudKitEdition: Bool {
        bundleIdentifier == "com.qssedalto.nexus.cloudkit.dev"
    }

    var showsDevelopmentLabel: Bool {
        isDevBuild && !isCloudKitEdition
    }

    static func current(bundle: Bundle = .main) -> AppBuildInfo {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Nexus"

        return AppBuildInfo(
            bundleIdentifier: bundle.bundleIdentifier ?? "com.qssedalto.nexus",
            displayName: displayName,
            variant: bundle.object(forInfoDictionaryKey: "NexusBuildVariant") as? String
        )
    }
}
