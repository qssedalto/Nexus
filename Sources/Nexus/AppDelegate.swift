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
    private let welcomeGuideStore = WelcomeGuideStore()
    private lazy var welcomeGuideController = WelcomeGuideWindowController(
        onOpenMenu: { [weak self] in
            self?.statusItemController?.showMenu()
        }
    )
    private var welcomeGuideObserver: NSObjectProtocol?


    func applicationWillTerminate(_ notification: Notification) {
        ClipboardHotkeyController.shared.shutdown()
        InputStatisticsController.shared.stopAndFlush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = serviceProvider
        if appState.shouldEnableDefaultLoginOnFirstLaunch {
            // Newly installed users only; respect a persisted disabled preference.
            appState.setLaunchAtLoginEnabled(true)
        }
        InputStatisticsController.shared.setClipboardShortcutHandler { [weak self] observation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch observation {
                case .copy:
                    // While history is paused there is no pasteboard read or write.
                    if !ClipboardMonitor.shared.isCollectingHistory {
                        self.appState.clipboardDidChange("Copy shortcut detected")
                    }
                case .paste: self.appState.clipboardDidChange("Paste detected")
                case .pasteRecorded: self.appState.refreshOperations()
                }
            }
        }
        InputStatisticsController.shared.refreshPermissionStatus()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                InputStatisticsController.shared.refreshPermissionStatus()
            }
        }
        _ = InputCloudBackupController.shared
        _ = NetworkSyncController.shared
        if UserDefaults.standard.bool(forKey: "nexusFolderClipboardEnabled"),
           UserDefaults.standard.bool(forKey: "nexusFolderClipboardAutomaticSync") {
            _ = ClipboardCloudController.shared
        }
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

        welcomeGuideObserver = NotificationCenter.default.addObserver(
            forName: .nexusShowWelcomeGuide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.welcomeGuideController.show() }
        }

        if welcomeGuideStore.shouldShowOnLaunch {
            welcomeGuideController.show()
            welcomeGuideStore.markShown()
        }
    }

    // Reopening a menu-bar-only app from Finder should never appear to do nothing,
    // even when another utility hides the status bar icon.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            welcomeGuideController.show()
        }
        return true
    }

}
