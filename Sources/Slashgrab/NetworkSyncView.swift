import Foundation
import Security
import SwiftUI
import SlashgrabCore

@MainActor
final class NetworkSyncController: ObservableObject {
    static let shared = NetworkSyncController()
    @Published var serverAddress: String {
        didSet { defaults.set(serverAddress, forKey: "nexusSyncServer") }
    }
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "nexusSyncAutomatic"); schedule() }
    }
    @Published var preciseEvents: Bool {
        didSet { defaults.set(preciseEvents, forKey: "nexusSyncPreciseEvents") }
    }
    @Published private(set) var status = "Idle"
    @Published private(set) var lastSync: Date?
    @Published private(set) var remoteSummary: [String: Int64] = [:]
    @Published private(set) var uploadPreview = ""
    @Published private(set) var log: [String] = []
    private let defaults: UserDefaults
    private let store = InputStatisticsStore.shared()
    private var timer: Timer?
    private let keychainService = "com.prof18.slashgrab.nexus-sync"

    private init() {
        defaults = .standard
        serverAddress = defaults.string(forKey: "nexusSyncServer") ?? "https://qsseda.com"
        automatic = defaults.bool(forKey: "nexusSyncAutomatic")
        preciseEvents = defaults.bool(forKey: "nexusSyncPreciseEvents")
        lastSync = defaults.object(forKey: "nexusSyncLastSuccess") as? Date
        schedule()
    }

    var hasToken: Bool { token() != nil }

    func saveToken(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "api-token"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        var saved = update == errSecSuccess
        if update == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            saved = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        status = saved ? "Token saved" : "Keychain error"
        return saved
    }

    func removeToken() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "api-token"]
        SecItemDelete(query as CFDictionary)
        status = "Token removed"
    }

    func testConnection() async {
        do {
            let request = try makeRequest(path: "/api/nexus/v1/me", method: "GET")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
            status = http.statusCode == 200 ? "Connected" : "HTTP \(http.statusCode)"
        } catch { status = error.localizedDescription }
    }

    func syncNow() async {
        guard let store else { status = "Statistics database unavailable"; return }
        do {
            let pending = try store.pendingSync()
            guard !pending.isEmpty else { status = "Up to date"; return }
            let deviceID = persistentDeviceID()
            let events = pending.map { event in
                UploadEvent(id: event.id, timeMS: preciseEvents && event.category != "ordinary" ? event.timeMS : (event.timeMS / 60_000) * 60_000, category: event.category, name: event.name, count: event.count)
            }
            var request = try makeRequest(path: "/api/nexus/v1/statistics/events", method: "POST")
            request.httpBody = try JSONEncoder().encode(UploadBatch(schemaVersion: 1, deviceID: deviceID, events: events))
            status = "Uploading"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
            let confirmation = try JSONDecoder().decode(UploadConfirmation.self, from: data)
            let submitted = Set(pending.map(\.id))
            guard Set(confirmation.acceptedIDs).isSubset(of: submitted) else { throw SyncError.invalidResponse }
            try store.markSynced(ids: confirmation.acceptedIDs, deviceID: deviceID)
            lastSync = Date()
            defaults.set(lastSync, forKey: "nexusSyncLastSuccess")
            status = "Uploaded \(confirmation.acceptedIDs.count) records"
            appendLog(status)
        } catch { status = error.localizedDescription; appendLog(status) }
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
        do {
            let request = try makeRequest(path: "/api/nexus/v1/statistics/events?device_id=\(persistentDeviceID())", method: "DELETE")
            let response: DeleteResponse = try await fetch(request)
            status = "Deleted \(response.deleted) remote records"
            appendLog(status)
        } catch { status = error.localizedDescription; appendLog(status) }
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func appendLog(_ message: String) {
        log.insert("\(Date().formatted(date: .abbreviated, time: .standard)) · \(message)", at: 0)
        if log.count > 30 { log.removeLast() }
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let base = URL(string: serverAddress), base.scheme == "https", base.host != nil,
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
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "api-token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func persistentDeviceID() -> String {
        if let existing = defaults.string(forKey: "nexusSyncDeviceID") { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: "nexusSyncDeviceID")
        return value
    }

    private func schedule() {
        timer?.invalidate()
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
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

    var body: some View {
        Form {
            TextField(localized("API server"), text: $controller.serverAddress)
            SecureField(localized("API token"), text: $token)
            HStack {
                Button(localized("Save token")) { if controller.saveToken(token) { token = "" } }
                Button(localized("Remove token")) { controller.removeToken() }
            }
            Toggle(localized("Automatic sync"), isOn: $controller.automatic)
            Toggle(localized("Precise non-text events"), isOn: $controller.preciseEvents)
            HStack {
                Button(localized("Test connection")) { Task { await controller.testConnection() } }
                Button(localized("Upload now")) { Task { await controller.syncNow() } }
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
        } message: { Text(localized("This deletes this device's server statistics.")) }
    }

    private var lower: Int64 { Int64(start.timeIntervalSince1970 * 1000) }
    private var upper: Int64 { Int64(end.timeIntervalSince1970 * 1000) }
}
