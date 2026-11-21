import AppKit
import NexusCore

@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nexusMonitorFileCopies")
            configureTimer()
        }
    }
    private let store = OperationStore.shared()
    private var timer: Timer?
    private var lastChangeCount: Int

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "nexusMonitorFileCopies")
        lastChangeCount = NSPasteboard.general.changeCount
        configureTimer()
    }

    private func configureTimer() {
        timer?.invalidate()
        guard enabled else { return }
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
        let detected = Int64(Date().timeIntervalSince1970 * 1000)
        let urls = URLDropReader.fileURLs(from: pasteboard)
        guard !urls.isEmpty, let store else { return }
        Task.detached(priority: .utility) {
            try? store.record(type: "copy", urls: urls, sourceApplication: nil, detectionMethod: "clipboard", detectedTimeMS: detected)
        }
    }
}
