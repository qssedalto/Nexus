import AppKit
import SlashgrabCore

@MainActor
final class NexusServiceProvider: NSObject {
    private let settings = SharedSettings.makeStore()
    private let formats = SharedSettings.makePathFormatReader()
    private let operationStore = OperationStore.shared()

    @objc(copySelectedPaths:userData:error:)
    func copySelectedPaths(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // File Provider and iCloud items may provide URL flavors differently.
        // Prefer the app's existing tolerant URL reader, then fall back to
        // Apple's native NSURL pasteboard reader. Never hydrate file contents.
        let recognized = URLDropReader.fileURLs(from: pasteboard)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let native = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]) ?? []
        let urls = recognized.isEmpty ? native.map { $0 as URL } : recognized
        guard !urls.isEmpty else {
            error.pointee = "No file URLs were provided by Finder" as NSString
            return
        }
        let action = PathCopyAction(clipboardWriter: AppKitClipboardWriter(), historyStore: settings, operationStore: operationStore)
        do {
            let completed = try action.copy(
                urls: urls, as: formats?.selectedFormat ?? .shellEscaped,
                sourceApplication: "Nexus Service", detectionMethod: "nsservices"
            )
            if completed != nil {
                ClipboardMonitor.shared.ignoreCurrentChange()
                DistributedNotificationCenter.default().post(
                    name: SharedSettings.finderCopyNotification, object: nil
                )
            }
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
