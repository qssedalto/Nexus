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

    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "nexusClipboardHistoryPaused")
            configureTimer()
        }
    }
    @Published var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: "nexusClipboardRetentionDays")
            configureTimer()
        }
    }
    @Published var maximumHistoryRecords: Int {
        didSet {
            UserDefaults.standard.set(maximumHistoryRecords, forKey: "nexusClipboardHistoryMaximum")
            configureTimer()
        }
    }
    @Published var excludedApps: String {
        didSet { UserDefaults.standard.set(excludedApps, forKey: "nexusClipboardExcludedApps") }
    }
    @Published private(set) var cleanupStatus = ""

    var onDetected: ((String) -> Void)?

    private let store = OperationStore.shared()
    private var timer: Timer?
    private var retentionTimer: Timer?
    private var lastChangeCount: Int
    private let maximumTextBytes = 1_048_576

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "nexusMonitorFileCopies")
        textEnabled = UserDefaults.standard.bool(forKey: "nexusMonitorTextCopies")
        paused = UserDefaults.standard.bool(forKey: "nexusClipboardHistoryPaused")
        retentionDays = max(0, UserDefaults.standard.integer(forKey: "nexusClipboardRetentionDays"))
        maximumHistoryRecords = max(0, UserDefaults.standard.integer(forKey: "nexusClipboardHistoryMaximum"))
        excludedApps = UserDefaults.standard.string(forKey: "nexusClipboardExcludedApps") ?? ""
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
        retentionTimer?.invalidate()
        timer = nil
        retentionTimer = nil
        lastChangeCount = NSPasteboard.general.changeCount
        guard !paused, enabled || textEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
        if retentionDays > 0 || maximumHistoryRecords > 0 {
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.cleanupNow() }
            }
            cleanupNow()
        }
    }

    func cleanupNow() {
        guard let store, retentionDays > 0 || maximumHistoryRecords > 0 else {
            cleanupStatus = localized("History retention is unlimited")
            return
        }
        let cutoff: Int64? = retentionDays > 0
            ? Int64(Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970 * 1000)
            : nil
        let protectedIDs = Set(
            (UserDefaults.standard.string(forKey: "nexusPinnedClipboardOperationIDs") ?? "")
                .split(separator: "\n").map(String.init)
        )
        let keep = maximumHistoryRecords > 0 ? maximumHistoryRecords : nil
        Task {
            let result = await Task.detached(priority: .background) {
                Result { try store.pruneHistory(olderThan: cutoff, keepingNewest: keep,
                                                protectedIDs: protectedIDs) }
            }.value
            switch result {
            case .success(let removed):
                cleanupStatus = "\(removed) \(localized("old records removed locally"))"
            case .failure(let error):
                cleanupStatus = error.localizedDescription
            }
        }
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // Password managers may attach a supported concealed/transient
        // pasteboard marker. Never read or persist these items.
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        if !types.isDisjoint(with: [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType"
        ]) { return }
        // This is a best-effort foreground-app exclusion, NOT a claim that
        // the pasteboard exposes a trustworthy copy-source app identity.
        let excluded = Set(excludedApps.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excluded.contains(frontmostID) { return }
        // This is the observation timestamp, not the originating app's
        // event timestamp nor proof of a completed file transfer.
        let detected = Int64(Date().timeIntervalSince1970 * 1000)

        let urls = URLDropReader.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            guard enabled, let store else { return }
            onDetected?("Clipboard files detected")
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
            onDetected?("Clipboard image detected")
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
        onDetected?("Clipboard text detected")
        Task.detached(priority: .utility) {
            try? store.record(type: "text_copy", urls: [], sourceApplication: nil,
                              detectionMethod: "clipboard", detectedTimeMS: detected,
                              clipboardText: text)
        }
    }
}
