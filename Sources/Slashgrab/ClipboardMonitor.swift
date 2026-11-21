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

    /// Opt-in storage of screenshot/image bytes is independent from
    /// file URL observations and text capture. Default is off.
    /// Separately opted-in sanitized RTF formatting; requires text capture.
    @Published var richTextEnabled: Bool {
        didSet {
            UserDefaults.standard.set(richTextEnabled, forKey: "nexusClipboardRichTextCapture")
        }
    }

    @Published var imageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(imageEnabled, forKey: "nexusClipboardImageCapture")
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
    // Increment only after a SQLite write succeeds; the shelf observes this
    // while visible rather than polling or racing the detached writer.
    @Published private(set) var savedRevision: UInt64 = 0

    var onDetected: ((String) -> Void)?

    private let store = OperationStore.shared()
    private var timer: Timer?
    private var retentionTimer: Timer?
    private var lastChangeCount: Int
    private let maximumTextBytes = 1_048_576
    private let maximumImageBytes = 8 * 1_024 * 1_024

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "nexusMonitorFileCopies")
        textEnabled = UserDefaults.standard.bool(forKey: "nexusMonitorTextCopies")
        imageEnabled = UserDefaults.standard.bool(forKey: "nexusClipboardImageCapture")
        richTextEnabled = UserDefaults.standard.bool(forKey: "nexusClipboardRichTextCapture")
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
        guard !paused, enabled || textEnabled || imageEnabled else { return }
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

    private func persist(_ write: @escaping @Sendable () throws -> Void) {
        Task { [weak self] in
            let committed = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try write()
                    return true
                } catch {
                    return false
                }
            }.value
            // This actor-bound revision is only a freshness signal. Clipboard
            // text and image bytes never travel through notifications.
            if committed {
                self?.savedRevision &+= 1
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
            persist {
                try store.record(type: "copy", urls: urls, sourceApplication: nil,
                                 detectionMethod: "clipboard", detectedTimeMS: detected)
            }
            return
        }

        // A screenshot/image-only clipboard has no trustworthy file URL.
        // Persist the original image only after separate consent. Images over
        // the payload limit or formats without decodable previews retain
        // metadata-only history. No image bytes are uploaded to the API.
        let imageTypes = Set([
            "public.png", "public.tiff", "public.jpeg", "public.heic",
            "com.compuserve.gif"
        ])
        let encodedImageType = pasteboard.types?.first(where: {
            imageTypes.contains($0.rawValue)
        })
        let imageDeclared = encodedImageType != nil
            || pasteboard.types?.contains(where: { $0.rawValue == "public.image" }) == true
        if (enabled || imageEnabled), imageDeclared, let store {
            onDetected?("Clipboard image detected")
            if imageEnabled, let encodedImageType,
               let data = pasteboard.data(forType: encodedImageType),
               data.count > 0 && data.count <= maximumImageBytes {
                let type = encodedImageType.rawValue
                persist {
                    if let thumbnail = ClipboardThumbnailMaker.jpegPreview(from: data) {
                        do {
                            try store.recordClipboardImage(
                                data: data, thumbnail: thumbnail,
                                pasteboardType: type, detectedTimeMS: detected
                            )
                            return
                        } catch {
                            // Preserve a metadata-only observation on failure.
                        }
                    }
                    try store.record(type: "image_copy", urls: [],
                                     sourceApplication: nil,
                                     detectionMethod: "clipboard_type",
                                     detectedTimeMS: detected)
                }
            } else {
                persist {
                    try store.record(type: "image_copy", urls: [],
                                     sourceApplication: nil,
                                     detectionMethod: "clipboard_type",
                                     detectedTimeMS: detected)
                }
            }
            return
        }

        guard textEnabled, let store,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text.utf8.count <= maximumTextBytes else { return }
        onDetected?("Clipboard text detected")
        // Read RTF only when the user authorized both plain-text history and
        // additional formatting, independently of image and file capture.
        // The parser runs on the utility queue and never retains raw RTF.
        let richRTF = richTextEnabled ? pasteboard.data(forType: .rtf) : nil
        persist {
            if let richRTF,
               let sanitized = ClipboardRTFParser.sanitizedPreview(from: richRTF) {
                try store.recordRichText(sanitized, detectedTimeMS: detected)
            } else {
                try store.record(type: "text_copy", urls: [],
                                 sourceApplication: nil,
                                 detectionMethod: "clipboard", detectedTimeMS: detected,
                                 clipboardText: text)
            }
        }
    }
}
