import AppKit
import NexusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState.production()
    let updater = SparkleUpdater()

    private var statusItemController: StatusItemController?
    private let serviceProvider = NexusServiceProvider()
    private var finderCopyObserver: NSObjectProtocol?
    private let finderExtensionMigrationController = FinderExtensionMigrationController.production()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = serviceProvider
        InputStatisticsController.shared.startIfPermitted()
        _ = NetworkSyncController.shared
        _ = ClipboardMonitor.shared
        finderCopyObserver = DistributedNotificationCenter.default().addObserver(
            forName: SharedSettings.finderCopyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appState.finderCopyDidSucceed() }
        }
        if FinderExtensionController.embeddedExtensionURL != nil {
            if let version = SharedSettings.finderExtensionVersion() {
                SharedSettings.makeFinderExtensionVersionStore()?.activate(version: version)
            }
            finderExtensionMigrationController.migrateIfNeeded()
        }

        let controller = StatusItemController(appState: appState)
        controller.install()

        statusItemController = controller
    }
}
