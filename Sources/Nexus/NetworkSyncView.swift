import Foundation
import Security
import SwiftUI
import NexusCore

/// Never follow a redirect carrying the user's bearer token or private
/// statistics/clipboard payload to an unexpected host or downgraded URL.
private final class NexusRejectHTTPRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class NetworkSyncController: ObservableObject {
    static let shared = NetworkSyncController()
    @Published var serverAddress: String {
        didSet {
            defaults.set(serverAddress, forKey: "nexusSyncServer")
            serverOperationsSupported = false
            serverStatisticsAggregatesSupported = false
            cancelInFlightUploads()
        }
    }
    /// Independent permission for uploading input statistics (including
    /// manual uploads). Defaults off: an old automatic-sync preference never
    /// silently grants network access to detailed input history.
    @Published var statisticsUploadEnabled: Bool {
        didSet {
            defaults.set(statisticsUploadEnabled, forKey: "nexusStatisticsUploadEnabled")
            if !statisticsUploadEnabled {
                statisticsTransferRevision &+= 1
                statisticsUploadTask?.cancel()
            }
        }
    }
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: "nexusSyncAutomatic")
            if !automatic {
                if statisticsUploadWasAutomatic { statisticsUploadTask?.cancel() }
                if operationUploadWasAutomatic { operationUploadTask?.cancel() }
            }
            schedule()
        }
    }
    @Published var preciseEvents: Bool {
        didSet {
            defaults.set(preciseEvents, forKey: "nexusSyncPreciseEvents")
            if !preciseEvents {
                statisticsTransferRevision &+= 1
                statisticsUploadTask?.cancel()
            }
        }
    }
    @Published private(set) var status = "Idle"
    @Published private(set) var serverOperationsSupported = false
    @Published private(set) var serverStatisticsAggregatesSupported = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var remoteSummary: [String: Int64] = [:]
    @Published var operationSyncEnabled: Bool {
        didSet {
            defaults.set(operationSyncEnabled, forKey: "nexusOperationSyncEnabled")
            if !operationSyncEnabled {
                operationConsentRevision &+= 1
                operationUploadTask?.cancel()
            }
        }
    }
    @Published var operationSyncPaths: Bool {
        didSet {
            defaults.set(operationSyncPaths, forKey: "nexusOperationSyncPaths")
            if !operationSyncPaths {
                operationConsentRevision &+= 1
                operationUploadTask?.cancel()
            }
        }
    }
    @Published var operationSyncText: Bool {
        didSet {
            defaults.set(operationSyncText, forKey: "nexusOperationSyncText")
            if !operationSyncText {
                operationConsentRevision &+= 1
                operationUploadTask?.cancel()
            }
        }
    }
    @Published private(set) var operationSyncStatus = "Not enabled"
    @Published private(set) var operationPreview = ""
    @Published private(set) var uploadPreview = ""
    @Published private(set) var log: [String] = []
    private let defaults: UserDefaults
    private let store = InputStatisticsStore.shared()
    private let operationStore = OperationStore.shared()
    private var timer: Timer?
    // A narrower permission cancels the underlying URLSession request when
    // possible. Already-delivered server requests cannot be recalled.
    private var operationConsentRevision: UInt64 = 0
    private var statisticsTransferRevision: UInt64 = 0
    private var operationUploadTask: Task<OperationSyncConfirmation, Error>?
    private var operationUploadWasAutomatic = false
    private var statisticsUploadTask: Task<UploadConfirmation, Error>?
    private var statisticsUploadWasAutomatic = false
    private var statisticsDeletionInProgress = false
    private var statisticsSyncPreparationInProgress = false
    private var operationDeletionInProgress = false
    private let keychainService = "com.qssedalto.nexus-sync"
    private let legacyKeychainService = "com.prof18.slashgrab.nexus-sync"
    private let legacyTokenFallbackDisabledKey = "nexusSyncLegacyTokenFallbackDisabled"
    private let credentialRevokedKey = "nexusSyncCredentialRevoked"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration,
                          delegate: NexusRejectHTTPRedirects(),
                          delegateQueue: nil)
    }()

    private init() {
        defaults = .standard
        serverAddress = defaults.string(forKey: "nexusSyncServer") ?? "https://qsseda.com"
        statisticsUploadEnabled = defaults.bool(forKey: "nexusStatisticsUploadEnabled")
        automatic = defaults.bool(forKey: "nexusSyncAutomatic")
        operationSyncEnabled = defaults.bool(forKey: "nexusOperationSyncEnabled")
        operationSyncPaths = defaults.bool(forKey: "nexusOperationSyncPaths")
        operationSyncText = defaults.bool(forKey: "nexusOperationSyncText")
        preciseEvents = defaults.bool(forKey: "nexusSyncPreciseEvents")
        lastSync = defaults.object(forKey: "nexusSyncLastSuccess") as? Date
        schedule()
    }

    var hasToken: Bool { token() != nil }

    func saveToken(_ value: String) -> Bool {
        // In-flight HTTP requests may carry the previous credential.
        cancelInFlightUploads()
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "api-token"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        var saved = update == errSecSuccess
        if update == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            saved = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        // Explicitly saving a Nexus credential opts out of silently reusing
        // an older app's token if this new item later becomes unavailable.
        if saved {
            defaults.set(true, forKey: legacyTokenFallbackDisabledKey)
            // Only an explicit successful save may re-enable credential use.
            defaults.set(false, forKey: credentialRevokedKey)
        }
        status = saved ? "Token saved" : "Keychain error"
        return saved
    }

    func removeToken() {
        cancelInFlightUploads()
        // Revocation must not destroy credentials that may still belong to
        // the user's original Slashgrab installation. Suppress future legacy
        // fallback before deleting only the Nexus-owned Keychain item.
        defaults.set(true, forKey: legacyTokenFallbackDisabledKey)
        // Fail closed even if Keychain refuses to delete the Nexus token:
        // stale credentials must never resume automatic uploads.
        defaults.set(true, forKey: credentialRevokedKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "api-token"
        ]
        let deletion = SecItemDelete(query as CFDictionary)
        serverOperationsSupported = false
        serverStatisticsAggregatesSupported = false
        status = (deletion == errSecSuccess || deletion == errSecItemNotFound)
            ? "Token removed" : "Keychain error; Nexus credential access disabled"
    }

    func testConnection() async {
        serverOperationsSupported = false
        serverStatisticsAggregatesSupported = false
        do {
            let request = try makeRequest(path: "/api/nexus/v1/me", method: "GET")
            let hello: ServerHello = try await fetch(request)
            guard hello.authenticated else { throw SyncError.invalidResponse }
            guard hello.schemaVersion == 1 else {
                status = localized("Server schema not recognized; operation sync not verified")
                return
            }
            serverOperationsSupported = (hello.capabilities ?? []).contains("operations.events")
            serverStatisticsAggregatesSupported = (hello.capabilities ?? []).contains("statistics.monotonic_aggregates")
            if !serverStatisticsAggregatesSupported {
                status = localized("Server connected but safe aggregate statistics retry is unavailable")
                return
            }
            status = localized(serverOperationsSupported
                ? "Connected: statistics and operation history APIs available"
                : "Connected: operation history API unavailable or not advertised")
        } catch {
            status = error.localizedDescription
        }
    }

    func syncNow(automaticRun: Bool = false) async {
        guard statisticsUploadEnabled else {
            status = localized("Statistics upload is disabled; local data is preserved")
            return
        }
        guard !statisticsDeletionInProgress else {
            status = "Statistics deletion in progress; upload blocked"
            return
        }
        guard PrivacyFeatureSwitchPolicy.shouldUploadStatistics(
            enabled: statisticsUploadEnabled,
            automaticRun: automaticRun,
            automatic: automatic
        ) else { return }
        guard statisticsUploadTask == nil && !statisticsSyncPreparationInProgress else {
            status = "Statistics upload already in progress"
            return
        }
        statisticsSyncPreparationInProgress = true
        defer { statisticsSyncPreparationInProgress = false }
        guard let store else { status = "Statistics database unavailable"; return }
        let transferRevision = statisticsTransferRevision
        do {
            let pending = try store.pendingSync()
            guard !pending.isEmpty else { status = "Up to date"; return }
            // The v1 endpoint predates aggregate uploads and acknowledges
            // duplicates even when it silently discards their increased
            // counts. Fail closed until the server explicitly advertises the
            // monotonic-upsert behavior; keep every local row pending.
            let hello: ServerHello = try await fetch(
                try makeRequest(path: "/api/nexus/v1/me", method: "GET")
            )
            serverStatisticsAggregatesSupported =
                hello.authenticated && hello.schemaVersion == 1
                && hello.capabilities?.contains("statistics.monotonic_aggregates") == true
            guard serverStatisticsAggregatesSupported else {
                status = localized("Statistics server requires aggregate retry support before upload")
                return
            }
            let deviceID = persistentDeviceID()
            // Ordinary character events are aggregated per UTC hour,
            // independently of the optional precise non-text event toggle.
            let plan = try InputUploadPrivacyPolicy.prepare(
                pending, preciseNonTextEvents: preciseEvents
            )
            let events = plan.events.map { event in
                UploadEvent(id: event.id, timeMS: event.timeMS,
                            category: event.category, name: event.name,
                            count: event.count)
            }
            var request = try makeRequest(path: "/api/nexus/v1/statistics/events", method: "POST")
            request.httpBody = try JSONEncoder().encode(UploadBatch(schemaVersion: 1, deviceID: deviceID, events: events))
            guard statisticsUploadEnabled,
                  transferRevision == statisticsTransferRevision,
                  (!automaticRun || automatic) else {
                status = "Statistics upload cancelled because settings changed"
                return
            }
            let submittedRequest = request
            let uploadTask = Task<UploadConfirmation, Error> {
                try await self.fetch(submittedRequest)
            }
            statisticsUploadTask = uploadTask
            statisticsUploadWasAutomatic = automaticRun
            defer {
                statisticsUploadTask = nil
                statisticsUploadWasAutomatic = false
            }
            status = "Uploading"
            let confirmation = try await uploadTask.value
            // Revocation must not mark a stale request as successfully synced.
            guard statisticsUploadEnabled,
                  transferRevision == statisticsTransferRevision,
                  !uploadTask.isCancelled, (!automaticRun || automatic) else {
                status = "Statistics request cancelled; check server before retrying"
                return
            }
            guard let acknowledgedSourceIDs = plan.sourceIDs(
                forAcknowledgedUploadIDs: confirmation.acceptedIDs
            ) else { throw SyncError.invalidResponse }
            // Only the source IDs represented by a confirmed aggregate may
            // be marked as synchronized. A revoked permission still leaves
            // the originals pending via the revision/cancellation guard above.
            try store.markSynced(ids: acknowledgedSourceIDs, deviceID: deviceID)
            lastSync = Date()
            defaults.set(lastSync, forKey: "nexusSyncLastSuccess")
            status = "Uploaded \(acknowledgedSourceIDs.count) local events in \(confirmation.acceptedIDs.count) aggregated records"
            appendLog(status)
        } catch is CancellationError {
            status = "Statistics request cancelled; an in-flight server request may already have arrived"
            appendLog(status)
        } catch { status = error.localizedDescription; appendLog(status) }
    }

    func previewOperations() {
        do {
            let pending = try operationStore?.pendingSync(limit: 25) ?? []
            operationPreview = "\(pending.count) pending (first page) · paths: \(operationSyncPaths ? "allowed" : "redacted") · text: \(operationSyncText ? "allowed" : "redacted")"
        } catch {
            operationPreview = error.localizedDescription
        }
    }

    func syncOperationsNow(automaticRun: Bool = false) async {
        guard !operationDeletionInProgress else {
            operationSyncStatus = "Remote operation deletion in progress; upload blocked"
            return
        }
        if automaticRun && !automatic { return }
        guard operationSyncEnabled else {
            operationSyncStatus = "Operation history upload requires separate consent"
            return
        }
        guard operationUploadTask == nil else {
            operationSyncStatus = "Operation upload already in progress"
            return
        }
        let consentRevision = operationConsentRevision
        let includePaths = operationSyncPaths
        let includeText = operationSyncText
        guard let operationStore else {
            operationSyncStatus = "Operation history database unavailable"
            return
        }
        do {
            let pending = try operationStore.pendingSync(limit: 25)
            guard !pending.isEmpty else {
                operationSyncStatus = "Operation history up to date"
                return
            }
            // An unusually large clipboard selection must not be truncated
            // silently and then marked synchronized.
            guard pending.allSatisfy({ $0.items.count <= 100 }) else {
                operationSyncStatus = "Too many selected files in one operation; cannot upload this batch"
                return
            }
            let upload = pending.map { record in
                SyncOperation(record: record, includePaths: includePaths,
                              includeText: includeText && (record.clipboardText?.count ?? 0) <= 100_000)
            }
            let body = try JSONEncoder().encode(OperationSyncBatch(
                deviceID: persistentDeviceID(), operations: upload))
            guard body.count <= 1_000_000 else {
                operationSyncStatus = "Operation batch exceeds safe size limit; nothing was acknowledged"
                return
            }
            var request = try makeRequest(path: "/api/nexus/v1/operations/events", method: "POST")
            request.httpBody = body
            // Re-read all live permission toggles immediately before starting
            // the HTTP task, not just while building the queued payload.
            guard operationSyncEnabled, operationConsentRevision == consentRevision,
                  (!automaticRun || automatic),
                  (!includePaths || operationSyncPaths),
                  (!includeText || operationSyncText) else {
                operationSyncStatus = "Operation upload cancelled because consent changed"
                return
            }
            let submittedRequest = request
            let uploadTask = Task<OperationSyncConfirmation, Error> {
                try await self.fetch(submittedRequest)
            }
            operationUploadTask = uploadTask
            operationUploadWasAutomatic = automaticRun
            defer {
                operationUploadTask = nil
                operationUploadWasAutomatic = false
            }
            operationSyncStatus = "Uploading operation metadata"
            let confirmation = try await uploadTask.value
            // A server may have processed an already-started request despite
            // cancellation. Never treat a revoked-consent response as approval.
            guard operationSyncEnabled, operationConsentRevision == consentRevision,
                  !uploadTask.isCancelled, (!automaticRun || automatic),
                  (!includePaths || operationSyncPaths),
                  (!includeText || operationSyncText) else {
                operationSyncStatus = "Consent changed or request cancelled; check server history for data already received"
                return
            }
            let expected = Set(pending.map(\.id))
            let accepted = Set(confirmation.acceptedIDs)
            guard !accepted.isEmpty && accepted.isSubset(of: expected) else {
                throw SyncError.invalidResponse
            }
            try operationStore.markSynced(operationIDs: Array(accepted))
            operationSyncStatus = "Uploaded \(accepted.count) operation records"
            appendLog(operationSyncStatus)
        } catch is CancellationError {
            operationSyncStatus = "Operation upload cancelled; an in-flight server request may already have arrived"
            appendLog(operationSyncStatus)
        } catch {
            // Leave records pending after timeout, auth failure, 4xx or 5xx.
            operationSyncStatus = error.localizedDescription
            appendLog("Operation metadata: " + operationSyncStatus)
        }
    }

    func restoreOperations(from startMS: Int64, to endMS: Int64) async {
        guard operationSyncEnabled, let operationStore else {
            operationSyncStatus = "Enable operation history sync to restore"
            return
        }
        let consentRevision = operationConsentRevision
        let includePaths = operationSyncPaths
        let includeText = operationSyncText
        guard startMS >= 0 && endMS > startMS else {
            operationSyncStatus = "Invalid time range"
            return
        }
        do {
            var offset = 0
            var inserted = 0
            repeat {
                let request = try makeRequest(
                    path: "/api/nexus/v1/operations/events?start_ms=\(startMS)&end_ms=\(endMS)&offset=\(offset)",
                    method: "GET"
                )
                let page: RemoteOperationPage = try await fetch(request)
                // Do not persist previously authorized remote text or paths
                // after the user revokes a permission during network latency.
                guard operationSyncEnabled, consentRevision == operationConsentRevision,
                      (!includePaths || operationSyncPaths),
                      (!includeText || operationSyncText) else {
                    operationSyncStatus = "Operation restore cancelled because consent changed"
                    return
                }
                let redacted = page.operations.map {
                    $0.redacted(includePaths: includePaths, includeText: includeText)
                }
                // Imported records use stable device-qualified IDs. They can
                // never enter the outbound local operation sync queue.
                inserted += try operationStore.importRemote(redacted)
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw SyncError.invalidResponse }
                offset = next
            } while offset <= 1_000_000
            operationSyncStatus = "Restored \(inserted) operation records"
            appendLog(operationSyncStatus)
        } catch {
            operationSyncStatus = error.localizedDescription
            appendLog("Operation restore: " + operationSyncStatus)
        }
    }

    func deleteRemoteOperations() async {
        // Deletion never requires turning upload back on. Revoke future
        // automatic and category-specific permissions before network access.
        automatic = false
        operationSyncEnabled = false
        operationSyncPaths = false
        operationSyncText = false
        guard operationUploadTask == nil && !operationDeletionInProgress else {
            operationSyncStatus = "An operation upload is still running; retry deletion once it completes"
            return
        }
        operationDeletionInProgress = true
        defer { operationDeletionInProgress = false }
        do {
            let request = try makeRequest(
                path: "/api/nexus/v1/operations/events?device_id=\(persistentDeviceID())",
                method: "DELETE"
            )
            let response: DeleteResponse = try await fetch(request)
            // Deletion from the server does NOT delete local history or
            // implicitly re-enqueue already acknowledged events.
            operationSyncStatus = "Deleted \(response.deleted) remote operation records"
            appendLog(operationSyncStatus)
        } catch {
            operationSyncStatus = error.localizedDescription
            appendLog("Operation delete: " + operationSyncStatus)
        }
    }

    func preview() {
        do {
            let pending = try store?.pendingSync() ?? []
            let categories = Dictionary(grouping: pending, by: \.category)
                .map { "\($0.key): \($0.value.reduce(0) { $0 + $1.count })" }
                .sorted().joined(separator: ", ")
            uploadPreview = "\(pending.count) records · \(categories)"
        } catch { uploadPreview = error.localizedDescription }
    }

    func queryRemote(from startMS: Int64, to endMS: Int64) async {
        do {
            let request = try makeRequest(path: "/api/nexus/v1/statistics/summary?start_ms=\(startMS)&end_ms=\(endMS)", method: "GET")
            let response: SummaryResponse = try await fetch(request)
            remoteSummary = Dictionary(grouping: response.statistics, by: \.name).mapValues { $0.reduce(0) { $0 + $1.count } }
            status = "Remote query complete"
        } catch { status = error.localizedDescription; appendLog(status) }
    }

    func restore(from startMS: Int64, to endMS: Int64) async {
        guard let store else { status = "Statistics database unavailable"; return }
        do {
            var offset = 0
            var inserted = 0
            repeat {
                let request = try makeRequest(path: "/api/nexus/v1/statistics/events?start_ms=\(startMS)&end_ms=\(endMS)&offset=\(offset)", method: "GET")
                let page: RemotePage = try await fetch(request)
                inserted += try store.importRemote(page.events)
                guard let next = page.nextOffset else { break }
                offset = next
            } while offset <= 1_000_000
            status = "Restored \(inserted) records"
            appendLog(status)
        } catch { status = error.localizedDescription; appendLog(status) }
    }

    func deleteRemoteDevice() async {
        automatic = false
        statisticsUploadEnabled = false
        guard statisticsUploadTask == nil && !statisticsSyncPreparationInProgress
                && !statisticsDeletionInProgress else {
            status = "A statistics upload is still running; retry deletion once it completes"
            return
        }
        statisticsDeletionInProgress = true
        defer { statisticsDeletionInProgress = false }
        do {
            let request = try makeRequest(path: "/api/nexus/v1/statistics/events?device_id=\(persistentDeviceID())", method: "DELETE")
            let response: DeleteResponse = try await fetch(request)
            status = "Deleted \(response.deleted) remote records"
            appendLog(status)
        } catch { status = error.localizedDescription; appendLog(status) }
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func appendLog(_ message: String) {
        log.insert("\(Date().formatted(date: .abbreviated, time: .standard)) · \(message)", at: 0)
        if log.count > 30 { log.removeLast() }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let base = URL(string: serverAddress), base.scheme == "https",
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              let token = token(), !token.isEmpty else { throw SyncError.configuration }
        guard let pathParts = URLComponents(string: path),
              var destination = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw SyncError.configuration }
        destination.path = pathParts.path
        destination.queryItems = pathParts.queryItems
        guard let url = destination.url else { throw SyncError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func token() -> String? {
        // Prefer the new Nexus Keychain service, but allow older user-created
        // credentials to remain readable when macOS Keychain access permits.
        // No existing credential is overwritten or silently uploaded.
        for service in [keychainService, legacyKeychainService] {
            // Once a user removes or replaces Nexus's API token, the old
            // application's token must never silently re-enable syncing.
            guard PrivacyFeatureSwitchPolicy.shouldReadStoredAPIToken(
                credentialRevoked: defaults.bool(forKey: credentialRevokedKey),
                isLegacyService: service == legacyKeychainService,
                legacyFallbackDisabled: defaults.bool(forKey: legacyTokenFallbackDisabledKey)
            ) else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "api-token",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func persistentDeviceID() -> String {
        if let existing = defaults.string(forKey: "nexusSyncDeviceID") { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: "nexusSyncDeviceID")
        return value
    }

    private func cancelInFlightUploads() {
        statisticsTransferRevision &+= 1
        operationConsentRevision &+= 1
        statisticsUploadTask?.cancel()
        operationUploadTask?.cancel()
    }

    private func schedule() {
        timer?.invalidate()
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow(automaticRun: true)
                if self?.automatic == true && self?.operationSyncEnabled == true {
                    await self?.syncOperationsNow(automaticRun: true)
                }
            }
        }
    }

    private struct ServerHello: Decodable {
        let authenticated: Bool
        let schemaVersion: Int?
        let capabilities: [String]?
        enum CodingKeys: String, CodingKey {
            case authenticated, capabilities
            case schemaVersion = "schema_version"
        }
    }

    private struct UploadBatch: Encodable {
        let schemaVersion: Int
        let deviceID: String
        let events: [UploadEvent]
        enum CodingKeys: String, CodingKey { case events; case schemaVersion = "schema_version"; case deviceID = "device_id" }
    }
    private struct UploadEvent: Encodable {
        let id: Int64
        let timeMS: Int64
        let category: String
        let name: String
        let count: Int64
        enum CodingKeys: String, CodingKey { case id, category, name, count; case timeMS = "time_ms" }
    }
    private struct UploadConfirmation: Decodable {
        let acceptedIDs: [Int64]
        enum CodingKeys: String, CodingKey { case acceptedIDs = "accepted_ids" }
    }
    private struct SummaryResponse: Decodable {
        let statistics: [SummaryRow]
    }
    private struct SummaryRow: Decodable {
        let name: String
        let count: Int64
    }
    private struct RemotePage: Decodable {
        let events: [RemoteInputEvent]
        let nextOffset: Int?
        enum CodingKeys: String, CodingKey { case events; case nextOffset = "next_offset" }
    }
    private struct DeleteResponse: Decodable { let deleted: Int }
    private enum SyncError: LocalizedError {
        case configuration, invalidResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .configuration: "HTTPS server and API token are required"
            case .invalidResponse: "Invalid server response"
            case .http(let code): "HTTP \(code)"
            }
        }
    }
}

struct NetworkSyncView: View {
    @ObservedObject private var controller = NetworkSyncController.shared
    @State private var token = ""
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var confirmRemoteDelete = false
    @State private var confirmOperationDelete = false
    @State private var showOperationSync = false

    var body: some View {
        Form {
            TextField(localized("API server"), text: $controller.serverAddress)
            SecureField(localized("API token"), text: $token)
            HStack {
                Button(localized("Save token")) { if controller.saveToken(token) { token = "" } }
                Button(localized("Remove token")) { controller.removeToken() }
            }
            Toggle(localized("Allow statistics upload to configured server"), isOn: $controller.statisticsUploadEnabled)
            Toggle(localized("Automatic sync"), isOn: $controller.automatic)
            Toggle(localized("Precise non-text events"), isOn: $controller.preciseEvents)
                .disabled(!controller.statisticsUploadEnabled)

            DisclosureGroup(localized("Copy history cloud sync (separate consent)"), isExpanded: $showOperationSync) {
                Toggle(localized("Allow operation metadata sync"), isOn: $controller.operationSyncEnabled)
                Toggle(localized("Include full source and target paths"), isOn: $controller.operationSyncPaths)
                    .disabled(!controller.operationSyncEnabled)
                Toggle(localized("Include copied text contents"), isOn: $controller.operationSyncText)
                    .disabled(!controller.operationSyncEnabled)
                Text(localized("Copied text and absolute file paths can contain passwords, personal names and private data. Both are redacted unless you opt in."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(localized("Preview pending operations")) {
                        controller.previewOperations()
                    }
                    Button(localized("Upload operation history now")) {
                        Task { await controller.syncOperationsNow() }
                    }.disabled(!controller.operationSyncEnabled)
                }
                HStack {
                    Button(localized("Restore operation history")) {
                        Task { await controller.restoreOperations(from: lower, to: upper) }
                    }.disabled(!controller.operationSyncEnabled)
                    Button(localized("Delete this device's remote operation history"), role: .destructive) {
                        confirmOperationDelete = true
                    }.disabled(!controller.hasToken)
                }
                Text(localized("Remote deletion is available even when operation uploads are disabled. Automatic sync and operation upload permissions are turned off before deletion."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(controller.operationPreview).font(.caption).textSelection(.enabled)
                LabeledContent(localized("Operation sync status"), value: controller.operationSyncStatus)
            }
            HStack {
                Button(localized("Test connection")) { Task { await controller.testConnection() } }
                Button(localized("Upload now")) { Task { await controller.syncNow() } }
                    .disabled(!controller.statisticsUploadEnabled)
                Button(localized("Preview upload")) { controller.preview() }
            }
            Text(controller.uploadPreview).font(.caption)
            HStack {
                DatePicker(localized("From"), selection: $start)
                DatePicker(localized("To"), selection: $end)
            }
            HStack {
                Button(localized("Query remote")) { Task { await controller.queryRemote(from: lower, to: upper) } }
                Button(localized("Restore remote")) { Task { await controller.restore(from: lower, to: upper) } }
                Button(localized("Delete remote device data"), role: .destructive) { confirmRemoteDelete = true }
            }
            ForEach(controller.remoteSummary.sorted(by: { $0.key < $1.key }), id: \.key) { row in
                LabeledContent(row.key, value: row.value.formatted())
            }
            ForEach(controller.log, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            LabeledContent(localized("Sync status"), value: controller.status)
            if let lastSync = controller.lastSync {
                LabeledContent(localized("Last sync"), value: lastSync.formatted())
            }
        }
        .formStyle(.grouped)
        .alert(localized("Delete remote device data"), isPresented: $confirmRemoteDelete) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Confirm"), role: .destructive) { Task { await controller.deleteRemoteDevice() } }
        } message: { Text(localized("This deletes this device's server statistics. Automatic sync will be turned off before deletion.")) }
        .alert(localized("Delete remote operation history"), isPresented: $confirmOperationDelete) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Confirm"), role: .destructive) {
                Task { await controller.deleteRemoteOperations() }
            }
        } message: {
            Text(localized("This deletes this device's copy operation records on the server. Automatic sync and operation upload permissions will be turned off; local records remain unchanged."))
        }
    }

    private var lower: Int64 { Int64(start.timeIntervalSince1970 * 1000) }
    private var upper: Int64 { Int64(end.timeIntervalSince1970 * 1000) }
}
