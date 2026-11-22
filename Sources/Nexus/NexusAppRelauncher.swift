import AppKit
import Security

@MainActor
enum NexusAppRelauncher {
    static let helperArgument = "--nexus-relaunch-helper"

    static func restart() {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        var runningCode: SecCode?
        var runningStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        var requirementData: CFData?
        guard appURL.pathExtension == "app", let executable = Bundle.main.executableURL,
              SecCodeCopySelf([], &runningCode) == errSecSuccess, let runningCode,
              SecCodeCopyStaticCode(runningCode, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode,
              SecCodeCopyDesignatedRequirement(runningStaticCode, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(runningCode, [], requirement) == errSecSuccess,
              matchesSignature(appURL, requirement: requirement),
              SecRequirementCopyData(requirement, [], &requirementData) == errSecSuccess,
              let requirementData else {
            showFailure(localized("The app on disk could not be verified against the running app. Open the verified copy from Finder."))
            return
        }

        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [
            helperArgument, String(ProcessInfo.processInfo.processIdentifier),
            appURL.path, (requirementData as Data).base64EncodedString()
        ]
        if CommandLine.arguments.contains("--nexus-permission-diagnostics") {
            helper.arguments?.append("--nexus-permission-diagnostics")
        }
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    static func runHelper() {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 || arguments.count == 6,
              let oldPID = pid_t(arguments[2]), oldPID > 1,
              let data = Data(base64Encoded: arguments[4]) else { exit(EXIT_FAILURE) }
        let appURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard appURL.path == Bundle.main.bundleURL.resolvingSymlinksInPath().path else {
            exit(EXIT_FAILURE)
        }

        // The helper lives outside the GUI process so it can wait through
        // AppKit termination and the statistics store's final SQLite flush.
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while kill(oldPID, 0) == 0 || errno == EPERM {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                showFailure(localized("The previous Nexus Drive process is still running. Quit it before reopening the app."))
                exit(EXIT_FAILURE)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess,
              let requirement, matchesSignature(appURL, requirement: requirement) else {
            showFailure(localized("The app on disk could not be verified against the running app. Open the verified copy from Finder."))
            exit(EXIT_FAILURE)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        if arguments.last == "--nexus-permission-diagnostics" {
            configuration.arguments = ["--nexus-permission-diagnostics"]
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                guard let app, app.processIdentifier != oldPID,
                      app.bundleURL?.resolvingSymlinksInPath().path == appURL.path else {
                    showFailure(error?.localizedDescription
                        ?? localized("macOS did not open the expected application. Open the verified copy from Finder."))
                    exit(EXIT_FAILURE)
                }
                exit(EXIT_SUCCESS)
            }
        }
        RunLoop.main.run()
    }

    private static func matchesSignature(_ appURL: URL, requirement: SecRequirement) -> Bool {
        var diskCode: SecStaticCode?
        return SecStaticCodeCreateWithPath(appURL as CFURL, [], &diskCode) == errSecSuccess
            && diskCode.map {
                SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
            } == true
    }

    private static func showFailure(_ message: String) {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = localized("Unable to restart Nexus Drive")
        alert.informativeText = message
        alert.runModal()
    }
}
