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

    /// Optional repeat policy. Existing users keep every text copy until
    /// they explicitly choose a consolidation strategy.
    @Published var textDuplicatePolicy: ClipboardTextDuplicatePolicy {
        didSet {
            UserDefaults.standard.set(
                textDuplicatePolicy.rawValue,
                forKey: "nexusClipboardTextDuplicatePolicy"
            )
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

    /// Optional local-only display of a copied URL's pasteboard-provided
    /// title. Default is off, independent of RTF and cloud-sync consent.
    @Published var linkTitleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                linkTitleEnabled, forKey: "nexusClipboardLinkTitleCapture"
            )
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
        linkTitleEnabled = UserDefaults.standard.bool(
            forKey: "nexusClipboardLinkTitleCapture"
        )
        textDuplicatePolicy = ClipboardTextDuplicatePolicy(
            rawValue: UserDefaults.standard.string(
                forKey: "nexusClipboardTextDuplicatePolicy"
            ) ?? ""
        ) ?? .keepAll
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
                if removed > 0 {
                    // Refresh the visible shelf after retained history is
                    // committed, not before the background cleanup finishes.
                    savedRevision &+= 1
                }
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
        // Check metadata from *every* pasteboard item before accessing
        // text, image bytes or file URLs. NSPasteboard.types may describe
        // only the first item, missing a concealed marker in a later item.
        let firstTypes = pasteboard.types?.map(\.rawValue) ?? []
        let itemTypes = (pasteboard.pasteboardItems ?? []).map {
            $0.types.map(\.rawValue)
        }
        if ClipboardSensitiveTypePolicy.shouldSkip(
            typeNamesByItem: [firstTypes] + itemTypes
        ) { return }
        // This is a best-effort foreground-app exclusion, NOT a claim that
        // the pasteboard exposes a trustworthy copy-source app identity.
        let excluded = Set(excludedApps.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let observedForegroundID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let observedForegroundID,
           excluded.contains(observedForegroundID) { return }
        // This is the observation timestamp, not the originating app's
        // event timestamp nor proof of a completed file transfer.
        let detected = Int64(Date().timeIntervalSince1970 * 1000)

        let urls = URLDropReader.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            guard enabled, let store else { return }
            onDetected?("Clipboard files detected")
            persist {
                try store.record(type: "copy", urls: urls,
                                 sourceApplication: observedForegroundID,
                                 detectionMethod: "clipboard_frontmost_observed",
                                 detectedTimeMS: detected)
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
                                pasteboardType: type, detectedTimeMS: detected,
                                observedForegroundBundleID: observedForegroundID
                            )
                            return
                        } catch {
                            // Preserve a metadata-only observation on failure.
                        }
                    }
                    try store.record(type: "image_copy", urls: [],
                                     sourceApplication: observedForegroundID,
                                     detectionMethod: "clipboard_frontmost_observed",
                                     detectedTimeMS: detected)
                }
            } else {
                persist {
                    try store.record(type: "image_copy", urls: [],
                                     sourceApplication: observedForegroundID,
                                     detectionMethod: "clipboard_frontmost_observed",
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
        // RTF and HTML formatting both require the existing independent
        // typography opt-in. HTML is parsed offline with a strict tag
        // allowlist, never rendered as a webpage or loaded by WebKit.
        let richRTF = richTextEnabled ? pasteboard.data(forType: .rtf) : nil
        let richHTML = richTextEnabled ? pasteboard.data(forType: .html) : nil
        let rawURLName = linkTitleEnabled
            ? pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            : nil
        let duplicatePolicy = textDuplicatePolicy
        persist {
            let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var sanitized: ClipboardRichTextPreview?
            var format = "rtf"
            if let richRTF,
               let candidate = ClipboardRTFParser.sanitizedPreview(from: richRTF),
               candidate.text.trimmingCharacters(in: .whitespacesAndNewlines) == original {
                sanitized = candidate
            } else if let richHTML, richHTML.count <= 128 * 1024,
                      let html = String(data: richHTML, encoding: .utf8),
                      let candidate = ClipboardSafeHTMLPreview.parse(html),
                      candidate.text.trimmingCharacters(in: .whitespacesAndNewlines) == original {
                sanitized = candidate
                format = "html"
            }
            let recordedID: String
            if let sanitized {
                recordedID = try store.recordRichText(
                    sanitized, detectedTimeMS: detected,
                    observedForegroundBundleID: observedForegroundID,
                    sourceFormat: format
                )
            } else {
                recordedID = try store.recordTextCopy(
                    text, detectedTimeMS: detected,
                    observedForegroundBundleID: observedForegroundID,
                    policy: duplicatePolicy
                )
            }
            // The URL's own pasteboard metadata is optional. A failed title
            // cache write must not lose the successfully committed copy.
            if let title = ClipboardLinkTitlePolicy.sanitized(
                rawURLName, copiedText: text
            ) {
                try? store.recordLinkTitle(operationID: recordedID, title: title)
            }
        }
    }
}
