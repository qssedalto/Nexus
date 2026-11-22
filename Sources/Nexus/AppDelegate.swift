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
        onOpenSettings: { [weak self] in self?.openSettingsFromWelcome() }
    )
    private var welcomeGuideObserver: NSObjectProtocol?


    func applicationWillTerminate(_ notification: Notification) {
        ClipboardHotkeyController.shared.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = serviceProvider
        if appState.shouldEnableDefaultLoginOnFirstLaunch {
            // Newly installed users only; respect a persisted disabled preference.
            appState.setLaunchAtLoginEnabled(true)
        }
        // Command-V only proves a request was seen, never destination success.
        // Reuse the existing short feedback popover when the user has explicitly
        // enabled paste-request observation.
        InputStatisticsController.shared.setPasteRequestHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.clipboardDidChange("Paste request observed")
            }
        }
        InputStatisticsController.shared.startIfPermitted()
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

    private func openSettingsFromWelcome() {
        welcomeGuideController.dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            if !opened {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }
}
