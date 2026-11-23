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

    /// The Drive channel is an isolated build for data safety, not a
    /// user-facing "DEV" product. Preserve internal .dev identity so it
    /// cannot replace or share state with an installed Nexus.app.
    var isDriveEdition: Bool {
        bundleIdentifier == "com.qssedalto.nexus.drive.dev"
    }

    var showsDevelopmentLabel: Bool {
        isDevBuild && !isDriveEdition
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
