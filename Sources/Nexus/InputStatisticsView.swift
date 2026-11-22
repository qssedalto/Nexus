import AppKit
import Charts
import OSLog
import SwiftUI
import NexusCore

@MainActor
final class InputStatisticsController: ObservableObject {
    static let shared = InputStatisticsController()
    @Published private(set) var counts: [InputCount] = []
    @Published private(set) var categoryCounts: [InputCategoryCount] = []
    @Published private(set) var sourceCounts: [InputSourceCount] = []
    @Published var selectedSource = ""
    @Published private(set) var overview = InputStatisticsOverview(
        keyboard: 0, mouse: 0, specialKeys: 0, shortcuts: 0,
        scrolls: 0, firstEventMS: nil)
    @Published private(set) var trend: [InputTrendBucket] = []
    @Published private(set) var trendRange: ClosedRange<Date>?
    @Published private(set) var trendRangeIsLimited = false
    @Published var trendResolution: InputTrendResolution = .hour
    @Published var selectedCategory = ""
    @Published var selectedKeyName = ""
    @Published private(set) var permissionState = InputPermissionState()
    var permissionGranted: Bool { permissionState.listeningGranted }
    var monitoringActive: Bool { permissionState.tap == .listening }
    private let permissions = SystemInputPermissions()
    private let logPermissionDiagnostics = CommandLine.arguments.contains("--nexus-permission-diagnostics")
    private var loggedPermissionState = false
    /// Defaults to on for existing users but remains under their control.
    /// Turning this off stops the event tap and related diagnostics.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nexusInputStatisticsEnabled")
            if !enabled { diagnosticsEnabled = false }
            refreshPermissionStatus()
        }
    }
    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "nexusInputPaused")
            configureDiagnostics()
            refreshPermissionStatus()
        }
    }
    @Published private(set) var dataStatus = ""
    @Published private(set) var diagnosticEvents: [InputDiagnosticEvent] = []
    @Published var diagnosticsEnabled = false {
        didSet { configureDiagnostics() }
    }
    private let store = InputStatisticsStore.shared()
    private var monitor: InputMonitor?
    private var permissionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        enabled = (UserDefaults.standard.object(
            forKey: "nexusInputStatisticsEnabled"
        ) as? Bool) ?? true
        paused = UserDefaults.standard.bool(forKey: "nexusInputPaused")
        if let store { monitor = InputMonitor(store: store) }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermissionStatus()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionStatus() }
        }
    }

    private func configureDiagnostics() {
        guard diagnosticsEnabled, enabled, !paused else {
            monitor?.onDiagnostic = nil
            diagnosticEvents.removeAll()
            return
        }
        diagnosticEvents.removeAll()
        monitor?.onDiagnostic = { [weak self] record in
            Task { @MainActor [weak self] in
                guard let self, self.diagnosticsEnabled, self.enabled, !self.paused else { return }
                self.diagnosticEvents.insert(record, at: 0)
                if self.diagnosticEvents.count > 25 {
                    self.diagnosticEvents.removeLast()
                }
            }
        }
    }

    func setClipboardShortcutHandler(_ handler: @escaping @Sendable (ClipboardShortcutObservation) -> Void) {
        monitor?.onClipboardShortcut = handler
    }

    func refreshPermissionStatus() {
        var state = permissionState
        state.refresh(
            permissions: permissions, listener: monitor, enabled: enabled,
            paused: paused, storage: store?.writeState
        )
        let changed = state != permissionState
        if changed { permissionState = state }
        if logPermissionDiagnostics, changed || !loggedPermissionState {
            loggedPermissionState = true
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nexus", category: "Permissions")
            logger.notice("CGPreflightListenEventAccess=\(state.listeningGranted, privacy: .public) AXIsProcessTrusted=\(state.accessibilityGranted, privacy: .public) tap=\(state.tap.rawValue, privacy: .public) receivedEvents=\(state.receivedEvents, privacy: .public) sqlite=\(state.storage?.rawValue ?? "unavailable", privacy: .public) enabled=\(self.enabled, privacy: .public) paused=\(self.paused, privacy: .public)")
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPermission() {
        _ = permissions.requestListening()
        refreshPermissionStatus()
        if !permissionGranted {
            // The OS may not show a second prompt after an earlier denial.
            // Bring up the real Input Monitoring page for manual approval.
            openInputMonitoringSettings()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAccessibilityPermission() {
        _ = permissions.requestAccessibility()
        refreshPermissionStatus()
        if !permissionState.accessibilityGranted { openAccessibilitySettings() }
    }

    func stopAndFlush() {
        monitor?.stop()
        try? store?.flushPending()
    }

    func refresh(from startMS: Int64, to endMS: Int64) {
        guard startMS >= 0, endMS > startMS else {
            dataStatus = localized("Invalid time range")
            return
        }
        guard let store else {
            dataStatus = localized("Local statistics database unavailable")
            return
        }
        do {
            let source = selectedSource.isEmpty ? nil : selectedSource
            counts = try store.counts(from: startMS, to: endMS)
            sourceCounts = try store.sourceCounts(from: startMS, to: endMS)
            categoryCounts = try store.categoryCounts(from: startMS, to: endMS, source: source)
            overview = try store.overview(from: startMS, to: endMS, source: source)
            let trendStart: Int64
            switch trendResolution {
            case .second: trendStart = max(startMS, endMS - 15 * 60_000)
            case .minute: trendStart = max(startMS, endMS - 48 * 3_600_000)
            default: trendStart = startMS
            }
            trend = try store.trend(from: trendStart, to: endMS,
                                    resolution: trendResolution,
                                    category: selectedCategory.isEmpty ? nil : selectedCategory,
                                    name: selectedKeyName.isEmpty ? nil : selectedKeyName,
                                    source: source)
            let displayStart = trendStart == 0 ? (trend.first?.startMS ?? trendStart) : trendStart
            let startDate = Date(timeIntervalSince1970: TimeInterval(displayStart) / 1_000)
            let endDate = Date(timeIntervalSince1970: TimeInterval(endMS) / 1_000)
            trendRange = startDate...endDate
            trendRangeIsLimited = trendStart > startMS
            dataStatus = localized("Statistics query complete")
        } catch {
            trend = []
            trendRange = nil
            trendRangeIsLimited = false
            dataStatus = error.localizedDescription
        }
        refreshPermissionStatus()
    }

    func checkIntegrity() {
        do { dataStatus = "SQLite: \(try store?.integrityCheck() ?? "unavailable")" }
        catch { dataStatus = error.localizedDescription }
    }

    func backup() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NexusStatistics.sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.backup(to: url); dataStatus = localized("Backup complete") }
        catch { dataStatus = error.localizedDescription }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NexusStatistics.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try store?.categoryCounts(from: 0, to: Int64.max) ?? []
            func escaped(_ text: String) -> String {
                "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let csv = "category,name,count\n" + rows.map {
                "\(escaped($0.category)),\(escaped($0.name)),\($0.count)"
            }.joined(separator: "\n") + "\n"
            try csv.write(to: url, atomically: true, encoding: .utf8)
            dataStatus = localized("Export complete")
        } catch { dataStatus = error.localizedDescription }
    }

    func delete(from startMS: Int64, to endMS: Int64) {
        do {
            let removed = try store?.delete(from: startMS, to: endMS) ?? 0
            dataStatus = "\(removed) \(localized("records deleted"))"
            refresh(from: startMS, to: endMS)
        } catch { dataStatus = error.localizedDescription }
    }

    var databaseSizeBytes: Int64 { store?.databaseSizeBytes ?? 0 }
}

struct InputStatisticsView: View {
    @ObservedObject private var controller = InputStatisticsController.shared
    @ObservedObject private var cloudBackup = InputCloudBackupController.shared
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var startSecond = 0
    @State private var endSecond = 59
    @State private var startMS = 0
    @State private var endMS = 999
    @State private var showingDeleteAlert = false
    @State private var diagnosticsExpanded = false
    @State private var deleteAllRequested = false
    @State private var selectedPreset = "today"
    @AppStorage("nexusInputSourceAliases") private var sourceAliasData = Data()
    @State private var editingSource: String?
    @State private var sourceAliasDraft = ""
    @State private var showingSourceAliasEditor = false

    private var sourceAliases: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: sourceAliasData)) ?? [:]
    }

    private var availableSources: [String] {
        Array(Set(controller.sourceCounts.map(\.source))).sorted()
    }

    private var sourceToRename: String? {
        if !controller.selectedSource.isEmpty { return controller.selectedSource }
        return availableSources.count == 1 ? availableSources.first : nil
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.permissionGranted ? localized("Input permission granted") : localized("Input permission required"))
                Spacer()
                if !controller.permissionGranted { Button(localized("Grant input permission")) { controller.requestPermission() } }
            }
            Toggle(localized("Enable keyboard and mouse statistics"), isOn: $controller.enabled)
            if controller.enabled && !controller.paused && controller.permissionGranted {
                Label(localized(controller.monitoringActive
                    ? "Keyboard and mouse monitoring is running."
                    : "Permission is granted, but event monitoring is not running."),
                    systemImage: controller.monitoringActive
                        ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(localized("Pause statistics"), isOn: $controller.paused)
                .disabled(!controller.enabled)
            Toggle(localized("Count held-key repeats"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "nexusCountKeyRepeats") },
                set: { UserDefaults.standard.set($0, forKey: "nexusCountKeyRepeats") }
            ))
                .disabled(!controller.enabled)
            Text(localized("When you hold a key, macOS may repeat it. On: count each repeated press. Off: count only the initial press."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(localized("Time range"), selection: $selectedPreset) {
                Text(localized("Last 15 minutes")).tag("recent_minutes")
                Text(localized("Last hour")).tag("recent_hour")
                Text(localized("Today")).tag("today")
                Text(localized("Yesterday")).tag("yesterday")
                Text(localized("Last 7 days")).tag("week")
                Text(localized("Last 30 days")).tag("month")
                Text(localized("This month")).tag("this_month")
                Text(localized("This year")).tag("year")
                Text(localized("All history")).tag("all")
                Text(localized("Custom")).tag("custom")
            }
            .onChange(of: selectedPreset) { _ in
                applyPreset()
            }
            // Two self-contained rows remain legible at the minimum Settings
            // width. A single long HStack previously overlapped the macOS tab strip.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(localized("From")).frame(width: 46, alignment: .leading)
                    DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    Text("s").foregroundStyle(.secondary)
                    TextField("ss", value: $startSecond, format: .number).frame(width: 40)
                    Text("ms").foregroundStyle(.secondary)
                    TextField("ms", value: $startMS, format: .number).frame(width: 50)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Text(localized("To")).frame(width: 46, alignment: .leading)
                    DatePicker("", selection: $end, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    Text("s").foregroundStyle(.secondary)
                    TextField("ss", value: $endSecond, format: .number).frame(width: 40)
                    Text("ms").foregroundStyle(.secondary)
                    TextField("ms", value: $endMS, format: .number).frame(width: 50)
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer()
                    Button(localized("Query"), action: query)
                }
            }
            .font(.caption)
            .padding(.vertical, 4)
            HStack {
                Picker(localized("Device or event source"), selection: $controller.selectedSource) {
                    Text(localized("All sources")).tag("")
                    ForEach(availableSources, id: \.self) { source in
                        Text(readableSource(source)).tag(source)
                    }
                }
                .onChange(of: controller.selectedSource) { _ in query() }
                Button(localized("Reset source filter")) {
                    controller.selectedSource = ""
                    query()
                }
                .disabled(controller.selectedSource.isEmpty)
                Button(localized("Rename source…")) {
                    if let sourceToRename { editSource(sourceToRename) }
                }
                .disabled(sourceToRename == nil)
            }
            HStack(spacing: 8) {
                statCard(localized("Keyboard presses"), controller.overview.keyboard, "keyboard")
                statCard(localized("Mouse clicks"), controller.overview.mouse, "cursorarrow.click")
                statCard(localized("Special keys"), controller.overview.specialKeys, "command")
            }
            HStack(spacing: 8) {
                statCard(localized("Shortcuts"), controller.overview.shortcuts, "keyboard.badge.ellipsis")
                statCard(localized("Scroll events"), controller.overview.scrolls, "arrow.up.arrow.down")
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("First recorded")).font(.caption).foregroundStyle(.secondary)
                    Text(controller.overview.firstEventMS.map {
                        Date(timeIntervalSince1970: TimeInterval($0)/1000)
                            .formatted(date: .abbreviated, time: .shortened)
                    } ?? localized("Unknown"))
                    .font(.caption).fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(localized("Time trend")).font(.headline)
                Spacer()
                Picker(localized("Resolution"), selection: $controller.trendResolution) {
                    Text(localized("Per second")).tag(InputTrendResolution.second)
                    Text(localized("Per minute")).tag(InputTrendResolution.minute)
                    Text(localized("Hourly")).tag(InputTrendResolution.hour)
                    Text(localized("Daily")).tag(InputTrendResolution.day)
                    Text(localized("Weekly")).tag(InputTrendResolution.week)
                    Text(localized("Monthly")).tag(InputTrendResolution.month)
                }
                .frame(width: 120)
                .onChange(of: controller.trendResolution) { _ in query() }
            }
            if let range = controller.trendRange {
                InputTrendChart(
                    buckets: controller.trend, range: range,
                    resolution: controller.trendResolution, limited: controller.trendRangeIsLimited
                )
                .id(range)
            }
            HStack {
                Text(localized("Key and shortcut ranking")).font(.headline)
                Spacer()
                Picker(localized("Event category"), selection: Binding(
                    get: { controller.selectedCategory },
                    set: {
                        controller.selectedCategory = $0
                        controller.selectedKeyName = ""
                        query()
                    }
                )) {
                    Text(localized("All")).tag("")
                    ForEach(["keyboard","modifier","system","shortcut","mouse","scroll","ordinary"], id: \.self) { category in
                        Text(localized(category)).tag(category)
                    }
                }
                .frame(width: 150)
            }
            List(controller.categoryCounts.filter {
                controller.selectedCategory.isEmpty || $0.category == controller.selectedCategory
            }) { count in
                Button {
                    controller.selectedCategory = count.category
                    controller.selectedKeyName = count.name
                    query()
                } label: {
                    HStack {
                        Label(readableEvent(count.name), systemImage: icon(for: count.name))
                        Text(localized(count.category)).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Text(Date(timeIntervalSince1970: TimeInterval(count.lastTimeMS)/1000)
                            .formatted(date: .numeric, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(count.count.formatted()).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 95, idealHeight: 150)
            if !controller.selectedKeyName.isEmpty {
                HStack {
                    Text("\(localized("Selected key")): \(readableEvent(controller.selectedKeyName))")
                    Button(localized("Show all keys")) {
                        controller.selectedKeyName = ""
                        query()
                    }
                }
                .font(.caption)
            }
            DisclosureGroup(localized("Source and HID device statistics")) {
                Text(localized("Only HID vendor/product and optional connection location identify a device model. Quartz and AppKit sources cannot identify a physical keyboard or mouse; location-free HID entries may represent several identical devices."))
                    .font(.caption).foregroundStyle(.secondary)
                List(controller.sourceCounts) { item in
                    Button {
                        controller.selectedSource = item.source
                        query()
                    } label: {
                        HStack {
                            Text(readableSource(item.source))
                                .font(.caption).lineLimit(2)
                            Text(localized(item.category)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(item.count.formatted()).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(localized("Rename source…")) { editSource(item.source) }
                    }
                }
                .frame(height: 145)
            }

            DisclosureGroup(localized("Special key detection"),
                            isExpanded: $diagnosticsExpanded) {
                Toggle(localized("Enable diagnostic key recognition"), isOn: $controller.diagnosticsEnabled)
                    .disabled(!controller.enabled)
                Text(localized("Diagnostics show only recognized functional keys and input categories. Unknown system key types are marked unsupported; ordinary text is never captured. Closing this section disables diagnostics."))
                    .font(.caption).foregroundStyle(.secondary)
                if controller.diagnosticsEnabled {
                    List(controller.diagnosticEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(readableEvent(event.name), systemImage: icon(for: event.name))
                                Spacer(minLength: 8)
                                Text(Date(timeIntervalSince1970: TimeInterval(event.timeMS) / 1000)
                                    .formatted(date: .omitted, time: .complete))
                                    .font(.caption2.monospacedDigit())
                            }
                            HStack(spacing: 8) {
                                Text(readableSource(event.source)).lineLimit(1)
                                if let code = event.keyCode {
                                    Text("keyCode \(code)").monospacedDigit()
                                }
                                if !event.modifiers.isEmpty {
                                    Text(event.modifiers.joined(separator: "+"))
                                }
                                if let kind = event.eventKind {
                                    Text(kind)
                                }
                                if event.isRepeat {
                                    Text(localized("Auto-repeat"))
                                }
                                if !event.supported {
                                    Text(localized("Unknown / unsupported"))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 175)
                }
            }
            HStack {
                Button(localized("Export CSV")) { controller.exportCSV() }
                Button(localized("Check database")) { controller.checkIntegrity() }
                Button(localized("Backup database")) { controller.backup() }
                Button(localized("Delete selected range")) {
                    deleteAllRequested = false
                    showingDeleteAlert = true
                }
                Button(localized("Delete all statistics"), role: .destructive) {
                    deleteAllRequested = true
                    showingDeleteAlert = true
                }
            }
            DisclosureGroup(localized("iCloud Drive statistics backup")) {
                Toggle(localized("Automatically back up statistics hourly"), isOn: $cloudBackup.enabled)
                Toggle(localized("Automatically merge other Macs' iCloud backups"), isOn: $cloudBackup.importOtherMacBackups)
                    .disabled(!cloudBackup.enabled)
                Text(localized("Backups are optional and contain detailed timing data. Choose an iCloud Drive folder explicitly; no backup is uploaded without your choice."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(localized("Cross-Mac import uses only the selected folder and separately named device snapshots, skips symlinks and backups over 100 MB, and preserves original event IDs across devices."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(localized("Choose backup folder")) { cloudBackup.selectDestination() }
                    Button(localized("Back up now")) { cloudBackup.backupNow() }
                    Button(localized("Restore backup…")) { cloudBackup.restoreSelectedBackup() }
                        .disabled(cloudBackup.restoring)
                    Button(localized("Import other Macs now")) {
                        cloudBackup.importOtherMacSnapshotsNow()
                    }
                    if cloudBackup.restoring { ProgressView().controlSize(.small) }
                }
                Text(localized("Each Mac receives its own backup subfolder. Restoring merges and deduplicates recorded statistics without erasing current events."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(cloudBackup.destinationSummary).font(.caption).textSelection(.enabled)
                Text(cloudBackup.status).font(.caption).foregroundStyle(.secondary)
                Text(cloudBackup.importStatus).font(.caption).foregroundStyle(.secondary)
                if let last = cloudBackup.lastBackup {
                    Text("\(localized("Last backup")): \(last.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(localized("Database size")): \(controller.databaseSizeBytes.formatted()) B · \(controller.dataStatus)")
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(localized("Rename source…"), isPresented: $showingSourceAliasEditor) {
            TextField(localized("Source alias"), text: $sourceAliasDraft)
            if let editingSource, sourceAliases[editingSource] != nil {
                Button(localized("Reset source name")) { saveSourceAlias("") }
            }
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Save")) { saveSourceAlias(sourceAliasDraft) }
        } message: {
            Text(localized("The name applies to this event source. Sources without device identifiers may combine multiple devices."))
        }
        .onAppear {
            controller.refreshPermissionStatus()
            applyPreset()
        }
        // Diagnostics are voluntary and scoped to the open test section.
        // Collapsing the section stops live diagnostic callbacks immediately.
        .onChange(of: diagnosticsExpanded) { expanded in
            if !expanded { controller.diagnosticsEnabled = false }
        }
        .onDisappear { controller.diagnosticsEnabled = false }
        .sheet(isPresented: $showingDeleteAlert) {
            StatisticsDeletionChallengeView(
                deleteAllRequested: deleteAllRequested,
                onCancel: {
                    showingDeleteAlert = false
                    deleteAllRequested = false
                },
                onConfirmed: {
                    let (lower, upper) = deleteAllRequested ? (Int64(0), Int64.max) : bounds
                    controller.delete(from: lower, to: upper)
                    showingDeleteAlert = false
                    deleteAllRequested = false
                }
            )
        }
    }

    private func editSource(_ source: String) {
        editingSource = source
        sourceAliasDraft = sourceAliases[source] ?? ""
        showingSourceAliasEditor = true
    }

    private func saveSourceAlias(_ value: String) {
        guard let editingSource else { return }
        let name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        var names = sourceAliases
        names[editingSource] = name.isEmpty ? nil : name
        if let data = try? JSONEncoder().encode(names) { sourceAliasData = data }
    }

    private func readableSource(_ source: String) -> String {
        let description = sourceDescription(source)
        guard let alias = sourceAliases[source] else { return description }
        return "\(alias) · \(description)"
    }

    private func sourceDescription(_ source: String) -> String {
        let parts = source.split(separator: ":", maxSplits: 1)
        switch parts.first {
        case "quartz_uptime": return localized("All keyboards and mice (device unavailable)")
        case "appkit_system_defined": return localized("System media keys (device unavailable)")
        case "iohid_consumer", "iohid_function":
            let label = localized(parts.first == "iohid_consumer" ? "HID media keys" : "HID function keys")
            let detail = String(parts.last ?? "")
            let segments = detail.components(separatedBy: ":name:")
            let productName = segments.count > 1 ? segments[1] : nil
            let fields = segments[0].split(separator: "_")
            guard fields.count == 6, fields[0] == "vendor", fields[2] == "product",
                  fields[4] == "location" else {
                return "\(label) · \(productName ?? localized("Device unknown"))"
            }
            let location = fields[5] == "unknown" ? localized("Unknown") : String(fields[5])
            let identity = String(format: localized("Vendor %@, product %@, location %@"),
                                         String(fields[1]), String(fields[3]), location)
            return "\(label) · \(productName ?? identity) · \(identity)"
        default: return "\(localized("Device unknown")) · \(source)"
        }
    }

    private func readableEvent(_ name: String) -> String {
        if name.count == 1 { return name.uppercased() }
        if name.first == "f", let number = Int(name.dropFirst()), (1...24).contains(number) {
            return "F\(number)"
        }
        if name.hasPrefix("key_") {
            let key = String(name.dropFirst(4))
            return key.count == 1 ? key.uppercased() : localized(key)
        }
        let tokens = name.split(separator: "_").map(String.init)
        let modifierSymbols = ["control":"⌃", "option":"⌥", "command":"⌘", "shift":"⇧", "fn":"Fn"]
        if tokens.count > 1, modifierSymbols[tokens[0]] != nil {
            let modifiers = tokens.prefix(while: { modifierSymbols[$0] != nil })
            let remainder = tokens.dropFirst(modifiers.count).joined(separator: "_")
            if !remainder.isEmpty {
                let label = readableEvent(remainder)
                return modifiers.compactMap { modifierSymbols[$0] }.joined() + " " + label
            }
        }
        if name.hasPrefix("mouse_extra_"), let number = Int64(name.dropFirst("mouse_extra_".count)),
           (0..<Int64.max).contains(number) {
            return String(format: localized("Mouse button %lld"), number + 1)
        }
        if name.hasPrefix("unrecognized_system_key_") { return localized("Unknown / unsupported") }
        return localized(name)
    }

    private func icon(for key: String) -> String {
        if key.contains("brightness") { return "sun.max" }
        if key.contains("volume") || key == "mute" { return "speaker.wave.2" }
        if key.contains("play") { return "playpause" }
        if key == "next" { return "forward.end" }
        if key == "previous" { return "backward.end" }
        if key == "spotlight_search" { return "magnifyingglass" }
        if key == "fn" { return "globe" }
        if key.contains("caps_lock") { return "capslock" }
        if key.contains("command") { return "command" }
        if key.contains("mouse") { return "cursorarrow.click" }
        if key.contains("scroll") { return "arrow.up.arrow.down" }
        if key.contains("f") { return "keyboard" }
        return "keyboard"
    }

    private func statCard(_ label: String, _ count: Int64, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(count.formatted())
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func applyPreset() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        switch selectedPreset {
        case "recent_minutes": start = now.addingTimeInterval(-15 * 60); end = now
        case "recent_hour": start = now.addingTimeInterval(-60 * 60); end = now
        case "today": start = today; end = now
        case "yesterday":
            start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            end = today.addingTimeInterval(-0.001)
        case "week": start = calendar.date(byAdding: .day, value: -7, to: now) ?? today; end = now
        case "month": start = calendar.date(byAdding: .day, value: -30, to: now) ?? today; end = now
        case "this_month": start = calendar.dateInterval(of: .month, for: now)?.start ?? today; end = now
        case "year": start = calendar.dateInterval(of: .year, for: now)?.start ?? today; end = now
        case "all": start = Date(timeIntervalSince1970: 0); end = now
        default: return
        }
        startSecond = calendar.component(.second, from: start)
        startMS = 0
        endSecond = calendar.component(.second, from: end)
        endMS = 999
        query()
    }

    private func query() {
        let (lower, upper) = bounds
        controller.refresh(from: lower, to: upper)
    }

    private var bounds: (Int64, Int64) {
        let lower = Int64(start.timeIntervalSince1970 / 60) * 60_000 + Int64(max(0, min(59, startSecond))) * 1000 + Int64(max(0, min(999, startMS)))
        let upper = Int64(end.timeIntervalSince1970 / 60) * 60_000 + Int64(max(0, min(59, endSecond))) * 1000 + Int64(max(0, min(999, endMS)))
        return (lower, upper)
    }
}

private struct InputTrendChart: View {
    let buckets: [InputTrendBucket]
    let range: ClosedRange<Date>
    let resolution: InputTrendResolution
    let limited: Bool

    @State private var hoveredBucket: Date?
    @State private var group = "all"
    @State private var excluded = Set<String>()
    @State private var separateScrolling = true

    private let categories = ["ordinary", "keyboard", "modifier", "system",
                              "shortcut", "mouse", "scroll"]
    private var calendar: Calendar { InputTrendResolution.bucketCalendar }

    private var categoriesForGroup: [String] {
        switch group {
        case "keyboard": return ["ordinary", "keyboard", "modifier", "system", "shortcut"]
        case "mouse": return ["mouse", "scroll"]
        default: return categories
        }
    }

    private var visibleBuckets: [InputTrendBucket] {
        let visible = Set(categoriesForGroup).subtracting(excluded)
        return buckets.filter { visible.contains($0.category) }
    }

    private var primaryBuckets: [InputTrendBucket] {
        visibleBuckets.filter { !separateScrolling || $0.category != "scroll" }
    }

    private var scrollingBuckets: [InputTrendBucket] {
        separateScrolling ? visibleBuckets.filter { $0.category == "scroll" } : []
    }

    private var hoveredDetails: [InputTrendBucket] {
        guard let hoveredBucket else { return [] }
        let timeMS = Int64(hoveredBucket.timeIntervalSince1970 * 1000)
        return visibleBuckets.filter { $0.startMS == timeMS }
            .sorted { $0.category < $1.category }
    }

    private var domain: ClosedRange<Date> {
        let start = calendar.dateInterval(of: resolution.calendarComponent, for: range.lowerBound)?.start
            ?? range.lowerBound
        let end = calendar.dateInterval(of: resolution.calendarComponent, for: range.upperBound)?.end
            ?? range.upperBound
        if resolution == .second || resolution == .minute || resolution == .hour,
           let first = visibleBuckets.map(\.startMS).min(),
           let last = visibleBuckets.map(\.startMS).max() {
            let padding: TimeInterval = resolution == .second ? 20 : (resolution == .minute ? 120 : 1800)
            let focusedStart = max(start, Date(timeIntervalSince1970: TimeInterval(first) / 1000 - padding))
            let focusedEnd = min(end, Date(timeIntervalSince1970: TimeInterval(last) / 1000 + padding))
            if focusedStart < focusedEnd { return focusedStart...focusedEnd }
        }
        return start...end
    }

    private var axisFormat: Date.FormatStyle {
        switch resolution {
        case .second: .dateTime.hour().minute().second()
        case .minute, .hour:
            range.upperBound.timeIntervalSince(range.lowerBound) >= 86_400
                ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()
        case .day, .week: .dateTime.month(.abbreviated).day()
        case .month: .dateTime.year().month(.abbreviated)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(localized("Chart focus"), selection: $group) {
                Text(localized("Overview")).tag("all")
                Text(localized("Keyboard")).tag("keyboard")
                Text(localized("Mouse")).tag("mouse")
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(categoriesForGroup, id: \.self) { category in
                    Button {
                        if excluded.contains(category) {
                            excluded.remove(category)
                        } else {
                            excluded.insert(category)
                        }
                    } label: {
                        Label(localized(category),
                              systemImage: excluded.contains(category) ? "circle" : "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if categoriesForGroup.contains("scroll") {
                Toggle(localized("Separate scroll-event scale"), isOn: $separateScrolling)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            if limited {
                Text(localized(resolution == .second
                    ? "This chart shows the last 15 minutes of the selected range."
                    : "This chart shows the last 48 hours of the selected range."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resolution == .second, visibleBuckets.contains(where: { $0.category == "ordinary" }) {
                Text(localized("Ordinary typing is counted by minute."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if visibleBuckets.isEmpty {
                Label(localized("No input events in this chart range"), systemImage: "chart.bar")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                if !primaryBuckets.isEmpty {
                    Text(localized("Input events")).font(.caption.weight(.semibold))
                    chart(primaryBuckets, height: 215)
                }
                if !scrollingBuckets.isEmpty {
                    Text(localized("Scroll events")).font(.caption.weight(.semibold))
                    chart(scrollingBuckets, height: 120)
                    Text(localized("Scrolling uses a separate count axis so large scroll totals do not hide other events."))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let hoveredBucket {
                    let total = hoveredDetails.reduce(Int64(0)) { $0 + $1.count }
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(hoveredBucket.formatted(axisFormat)).fontWeight(.semibold)
                            Spacer()
                            Text(total.formatted()).monospacedDigit()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)],
                                  alignment: .leading, spacing: 6) {
                            ForEach(hoveredDetails) { detail in
                                HStack {
                                    Text(localized(detail.category)).lineLimit(1)
                                    Spacer()
                                    Text(detail.count.formatted()).monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Text(localized("Point at the chart to see the time and event count."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: resolution) { _ in hoveredBucket = nil }
        .onChange(of: group) { _ in hoveredBucket = nil }
        .onChange(of: excluded) { _ in hoveredBucket = nil }
        .onChange(of: separateScrolling) { _ in hoveredBucket = nil }
    }

    private func chart(_ plotted: [InputTrendBucket], height: CGFloat) -> some View {
        Chart {
            ForEach(plotted) { bucket in
                BarMark(
                    x: .value(localized("Time"),
                              Date(timeIntervalSince1970: TimeInterval(bucket.startMS) / 1000),
                              unit: resolution.calendarComponent, calendar: calendar),
                    y: .value(localized("Count"), bucket.count)
                )
                .foregroundStyle(by: .value(localized("Category"), localized(bucket.category)))
            }
            if let hoveredBucket {
                RuleMark(x: .value(localized("Time"), hoveredBucket))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            if resolution == .day || resolution == .week || resolution == .month {
                AxisMarks(values: .stride(by: resolution == .month ? .month : .day, count: 1)) {
                    AxisGridLine()
                    AxisValueLabel(format: axisFormat)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel(format: axisFormat)
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: height)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase,
                              geometry[proxy.plotAreaFrame].contains(location),
                              let date: Date = proxy.value(
                                atX: location.x - geometry[proxy.plotAreaFrame].minX
                              )
                        else {
                            hoveredBucket = nil
                            return
                        }
                        hoveredBucket = calendar.dateInterval(
                            of: resolution.calendarComponent, for: date
                        )?.start
                    }
            }
        }
    }
}
