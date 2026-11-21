import AppKit
import SlashgrabCore

@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nexusMonitorFileCopies")
            configureTimer()
        }
    }

    // Text history is independently opt-in. A clipboard may contain secrets,
    // so enabling file URL history must never silently enable text capture.
    @Published var textEnabled: Bool {
        didSet {
            UserDefaults.standard.set(textEnabled, forKey: "nexusMonitorTextCopies")
            configureTimer()
        }
    }

    private let store = OperationStore.shared()
    private var timer: Timer?
    private var lastChangeCount: Int
    private let maximumTextBytes = 1_048_576

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "nexusMonitorFileCopies")
        textEnabled = UserDefaults.standard.bool(forKey: "nexusMonitorTextCopies")
        lastChangeCount = NSPasteboard.general.changeCount
        configureTimer()
    }

    /// Called after Nexus itself writes to the pasteboard so the passive
    /// observer does not record a second duplicate operation.
    func ignoreCurrentChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard enabled || textEnabled else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // This is the observation timestamp, not the originating app's
        // event timestamp nor proof of a completed file transfer.
        let detected = Int64(Date().timeIntervalSince1970 * 1000)

        let urls = URLDropReader.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            guard enabled, let store else { return }
            Task.detached(priority: .utility) {
                try? store.record(type: "copy", urls: urls, sourceApplication: nil,
                                  detectionMethod: "clipboard", detectedTimeMS: detected)
            }
            return
        }

        // A screenshot/image-only clipboard has no trustworthy file URL.
        // Observe its declared type only; never load bitmap data or thumbnails.
        if enabled, let store,
           pasteboard.types?.contains(where: {
               ["public.png", "public.tiff", "public.jpeg", "public.heic",
                "com.compuserve.gif", "public.image"].contains($0.rawValue)
           }) == true {
            Task.detached(priority: .utility) {
                try? store.record(type: "image_copy", urls: [], sourceApplication: nil,
                                  detectionMethod: "clipboard_type", detectedTimeMS: detected)
            }
            return
        }

        guard textEnabled, let store,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text.utf8.count <= maximumTextBytes else { return }
        Task.detached(priority: .utility) {
            try? store.record(type: "text_copy", urls: [], sourceApplication: nil,
                              detectionMethod: "clipboard", detectedTimeMS: detected,
                              clipboardText: text)
        }
    }
}
