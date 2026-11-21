import Foundation
import SlashgrabCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var history: PathHistory
    @Published private(set) var feedback: DropFeedback?
    @Published var selectedFormat: PathFormat
    @Published private(set) var launchAtLoginEnabled: Bool
    private(set) var shouldEnableDefaultLoginOnFirstLaunch = false
    @Published private(set) var finderExtensionEnabled: Bool
    @Published private(set) var useFinderSubmenu: Bool
    @Published private(set) var feedbackDuration: Double
    @Published private(set) var operations: [RecordedOperation] = []
    @Published private(set) var shelfOperations: [RecordedOperation] = []

    private let settings: AppSettingsStore
    private let sharedSettings: AppSettingsStore?
    private let formatter: PathFormatter
    private let clipboardWriter: ClipboardWriting
    private let operationStore: OperationStore?
    private let launchAtLoginController: LaunchAtLoginControlling
    private let finderExtensionController: FinderExtensionManaging
    private var feedbackTask: Task<Void, Never>?
    private var operationQueryID = UUID()
    private var shelfQueryID = UUID()

    init(
        settings: AppSettingsStore,
        sharedSettings: AppSettingsStore? = nil,
        formatter: PathFormatter = PathFormatter(),
        clipboardWriter: ClipboardWriting = AppKitClipboardWriter(),
        launchAtLoginController: LaunchAtLoginControlling = LaunchAtLoginController(),
        finderExtensionController: FinderExtensionManaging = FinderExtensionController(),
        operationStore: OperationStore? = nil
    ) {
        self.settings = settings
        self.sharedSettings = sharedSettings
        self.formatter = formatter
        self.clipboardWriter = clipboardWriter
        self.operationStore = operationStore
        self.launchAtLoginController = launchAtLoginController
        self.finderExtensionController = finderExtensionController
        let storedFormat = settings.selectedFormat
        selectedFormat = storedFormat
        sharedSettings?.selectedFormat = storedFormat
        history = Self.mergedHistory(
            newest: sharedSettings?.loadHistory(),
            existing: settings.loadHistory(),
            limit: settings.historyLimit
        )
        let currentLaunchAtLoginEnabled = launchAtLoginController.isEnabled
        launchAtLoginEnabled = currentLaunchAtLoginEnabled
        finderExtensionEnabled = finderExtensionController.isEnabled
        useFinderSubmenu = (sharedSettings ?? settings).useFinderSubmenu
        feedbackDuration = settings.feedbackDuration
        settings.launchAtLoginEnabled = currentLaunchAtLoginEnabled
        persistHistory()
        refreshOperations()
    }

    static func production() -> AppState {
        let settings = AppSettingsStore(defaults: .standard)
        // The initializer persists the current state; remember whether a
        // preference existed BEFORE it runs. Never re-enable launch at login
        // for an existing user who disabled it intentionally.
        let firstLaunch = !settings.hasStoredLaunchAtLoginPreference
        let state = AppState(
            settings: settings,
            sharedSettings: SharedSettings.makeStore(),
            operationStore: OperationStore.shared()
        )
        state.shouldEnableDefaultLoginOnFirstLaunch = firstLaunch
        return state
    }

    var lastCopiedOutput: String? {
        history.entries.first
    }

    func setSelectedFormat(_ format: PathFormat) {
        selectedFormat = format
        settings.selectedFormat = format
        sharedSettings?.selectedFormat = format
    }

    @discardableResult
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            showFeedback(.failure(localized("Unsupported drop")))
            return false
        }

        let eventTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
        let output = formatter.format(urls: urls, as: selectedFormat)
        return copyOutput(output, successMessage: localized("Path copied"), urls: urls, eventTimeMS: eventTimeMS)
    }

    @discardableResult
    func copyAgain(_ output: String) -> Bool {
        copyOutput(output, successMessage: localized("Copied again"))
    }

    func refreshHistory() {
        refreshOperations()
        guard let sharedSettings else {
            history = settings.loadHistory()
            return
        }

        let sharedHistory = sharedSettings.loadHistory()
        guard sharedHistory != history else {
            return
        }

        history = Self.mergedHistory(
            newest: sharedHistory,
            existing: history,
            limit: settings.historyLimit
        )
        persistHistory()
    }

    // Reuse the single existing status-bar feedback popover for passive
    // clipboard changes. Detection does not imply successful paste.
    func clipboardDidChange(_ key: String) {
        showFeedback(.observed(localized(key)))
    }

    func finderCopyDidSucceed() {
        refreshHistory()
        showFeedback(.success(localized("Path copied")))
    }

    /// The initial menu/settings refresh uses only recent records. Explicit
    /// timeline range queries keep their full, user-selected range.
    func refreshOperations(from startMS: Int64? = nil, to endMS: Int64 = Int64.max) {
        let queryID = UUID()
        operationQueryID = queryID
        let store = operationStore
        let lower = startMS ?? Int64(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970 * 1000)
        let implicitLimit: Int? = startMS == nil ? 500 : nil
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                (try? store?.query(from: lower, to: endMS, limit: implicitLimit)) ?? []
            }.value
            guard self?.operationQueryID == queryID else { return }
            self?.operations = results
        }
    }

    /// Separate shelf data from the unbounded, user-specified timeline query.
    /// Loading 200 latest clipboard records (not unrelated operation events)
    /// plus explicit pinned/collection UUIDs keeps
    /// old favorites visible without materializing years of copy operations.
    func refreshShelfOperations(protectedIDs: [String] = []) {
        let queryID = UUID()
        shelfQueryID = queryID
        let store = operationStore
        let ids = Array(Set(protectedIDs)).sorted()
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                let recent = (try? store?.searchClipboard(query: "", limit: 200)) ?? []
                let protected = (try? store?.query(ids: ids)) ?? []
                var byID: [String: RecordedOperation] = [:]
                for operation in recent + protected { byID[operation.id] = operation }
                return byID.values.sorted {
                    let lhs = $0.eventTimeMS ?? $0.detectedTimeMS
                    let rhs = $1.eventTimeMS ?? $1.detectedTimeMS
                    return lhs == rhs ? $0.id > $1.id : lhs > rhs
                }
            }.value
            guard self?.shelfQueryID == queryID else { return }
            self?.shelfOperations = results
        }
    }

    func clearHistory() {
        history.clear()
        persistHistory()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLoginController.isEnabled
            settings.launchAtLoginEnabled = launchAtLoginEnabled
            showFeedback(launchAtLoginEnabled ? .success(localized("Launch at login on")) : .success(localized("Launch at login off")))
        } catch {
            launchAtLoginEnabled = launchAtLoginController.isEnabled
            settings.launchAtLoginEnabled = launchAtLoginEnabled
            showFeedback(.failure(localized("Launch at login failed")))
        }
    }

    func refreshFinderExtensionStatus() {
        finderExtensionEnabled = finderExtensionController.isEnabled
    }

    func setUseFinderSubmenu(_ enabled: Bool) {
        (sharedSettings ?? settings).useFinderSubmenu = enabled
        useFinderSubmenu = enabled
    }

    func setFeedbackDuration(_ duration: Double) {
        feedbackDuration = duration
        settings.feedbackDuration = duration
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = launchAtLoginController.isEnabled
        settings.launchAtLoginEnabled = launchAtLoginEnabled
    }

    func showFinderExtensionSettings() {
        finderExtensionController.showManagementInterface()
    }

    @discardableResult
    private func copyOutput(_ output: String, successMessage: String, urls: [URL] = [], eventTimeMS: Int64? = nil) -> Bool {
        let startedTimeMS = eventTimeMS ?? Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try clipboardWriter.writeString(output)
            let completedTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
            // The dedicated Nexus operation is recorded below. Prevent the
            // passive clipboard observer from adding a duplicate text event.
            ClipboardMonitor.shared.ignoreCurrentChange()
            refreshHistory()
            history.add(output)
            persistHistory()

            let operationStore = self.operationStore
            // A menu-bar file drop is a distinct user action from
            // Finder's native copy-path service, even though both write
            // formatted paths into the system clipboard.
            let operationType = urls.isEmpty ? "text_copy" : "drop_copy"
            let method = urls.isEmpty ? "app_recopy" : "drop"
            Task { [weak self] in
                await Task.detached(priority: .utility) {
                    try? operationStore?.record(type: operationType, urls: urls,
                                                sourceApplication: "Nexus", detectionMethod: method,
                                                eventTimeMS: startedTimeMS,
                                                detectedTimeMS: completedTimeMS,
                                                completedTimeMS: completedTimeMS,
                                                clipboardText: output)
                }.value
                self?.refreshOperations()
            }
            let detail = urls.count == 1 ? urls[0].lastPathComponent : (urls.isEmpty ? nil : "\(urls.count) \(localized("items"))")
            showFeedback(.success(successMessage, detail: detail))
            return true
        } catch {
            showFeedback(.failure(localized("Clipboard write failed")))
            return false
        }
    }

    private func showFeedback(_ feedback: DropFeedback) {
        feedbackTask?.cancel()
        guard feedbackDuration > 0 else { self.feedback = nil; return }
        self.feedback = feedback
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.feedbackDuration ?? 0.9))
            await MainActor.run {
                if !Task.isCancelled {
                    self?.feedback = nil
                }
            }
        }
    }

    private func persistHistory() {
        settings.saveHistory(history)
        sharedSettings?.saveHistory(history)
    }

    private static func mergedHistory(
        newest: PathHistory?,
        existing: PathHistory,
        limit: Int
    ) -> PathHistory {
        var entries: [String] = []
        for entry in (newest?.entries ?? []) + existing.entries where !entries.contains(entry) {
            entries.append(entry)
        }
        return PathHistory(entries: entries, limit: limit)
    }
}

struct DropFeedback: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case failure
        case observation
    }

    let id = UUID()
    let kind: Kind
    let message: String
    let detail: String?

    static func success(_ message: String, detail: String? = nil) -> DropFeedback {
        DropFeedback(kind: .success, message: message, detail: detail)
    }

    static func observed(_ message: String) -> DropFeedback {
        DropFeedback(kind: .observation, message: message, detail: nil)
    }

    static func failure(_ message: String) -> DropFeedback {
        DropFeedback(kind: .failure, message: message, detail: nil)
    }
}
