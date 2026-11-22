import AppKit
import Foundation

/// Restart exactly this installed bundle after macOS changes a TCC grant.
/// A fresh process is sometimes required for Input Monitoring or Accessibility
/// permissions to take effect. Restart only on an explicit user action.
@MainActor
enum NexusAppRelauncher {
    static func restart() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as a positional argument, not interpolated into
        // shell source, so spaces/quotes in the install path are safe.
        helper.arguments = [
            "-c",
            "/bin/sleep 1; exec /usr/bin/open -n \"$1\"",
            "nexus-relaunch",
            appURL.path
        ]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = localized("Unable to restart Nexus Drive")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
