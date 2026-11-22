import SwiftUI

@main
enum NexusEntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == NexusAppRelauncher.helperArgument {
            NexusAppRelauncher.runHelper()
        } else {
            NexusApp.main()
        }
    }
}

struct NexusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                appState: appDelegate.appState,
                buildInfo: .current(),
                updater: appDelegate.updater
            )
        }
    }
}
