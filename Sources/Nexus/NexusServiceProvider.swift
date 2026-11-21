import AppKit
import NexusCore

@MainActor
final class NexusServiceProvider: NSObject {
    private let settings = SharedSettings.makeStore()
    private let formats = SharedSettings.makePathFormatReader()
    private let operationStore = OperationStore.shared()

    @objc(copySelectedPaths:userData:error:)
    func copySelectedPaths(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? URLDropReader.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "No file URLs were provided by Finder" as NSString
            return
        }
        let action = PathCopyAction(clipboardWriter: AppKitClipboardWriter(), historyStore: settings, operationStore: operationStore)
        do {
            try action.copy(urls: urls, as: formats?.selectedFormat ?? .shellEscaped)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
