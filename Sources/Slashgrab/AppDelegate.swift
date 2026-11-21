import AppKit
import SlashgrabCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState.production()
    let updater = SparkleUpdater()

    private var statusItemController: StatusItemController?
    private let serviceProvider = NexusServiceProvider()
    private var finderCopyObserver: NSObjectProtocol?
    private let finderExtensionMigrationController = FinderExtensionMigrationController.production()

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardHotkeyController.shared.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = serviceProvider
        // Observed paste shortcuts are NOT proof of a successful paste.
        // Show the same neutral, non-focus-stealing popover used for passive
        // clipboard observations, only after the separate consent is enabled.
        let state = appState
        InputStatisticsController.shared.setPasteRequestHandler { _ in
            Task { @MainActor in
                state.clipboardDidChange("Paste request detected")
            }
        }
        InputStatisticsController.shared.startIfPermitted()
        _ = InputCloudBackupController.shared
        _ = NetworkSyncController.shared
        ClipboardMonitor.shared.onDetected = { [weak self] key in
            self?.appState.clipboardDidChange(key)
        }
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
