import FinderSync
import Foundation

@MainActor
protocol FinderExtensionManaging {
    var isEnabled: Bool { get }
    func showManagementInterface()
}

@MainActor
struct FinderExtensionController: FinderExtensionManaging {
    static var embeddedExtensionURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("NexusFinderSync.appex"),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    var isEnabled: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    func showManagementInterface() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}
