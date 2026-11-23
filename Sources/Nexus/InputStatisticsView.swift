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
    @AppStorage("nexusInputKeyAliases") private var keyAliasData = Data()
    @State private var editingKeyAlias: String?
    @State private var keyAliasDraft = ""
    @State private var showingKeyAliasEditor = false

    private var keyAliases: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: keyAliasData)) ?? [:]
    }

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
            if selectedPreset == "custom" {
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
            }
            HStack {
                Picker(localized("Device or event source"), selection: $controller.selectedSource) {
                    Text(localized("All sources")).tag("")
                    ForEach(availableSources, id: \.self) { source in
                        Text(readableSource(source)).tag(source)
                    }
                }
                .onChange(of: controller.selectedSource) { _ in query() }
                Menu {
                    Button(localized("Reset source filter")) {
                        controller.selectedSource = ""
                        query()
                    }
                    .disabled(controller.selectedSource.isEmpty)
                    Button(localized("Rename source…")) {
                        if let sourceToRename { editSource(sourceToRename) }
                    }
                    .disabled(sourceToRename == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(localized("Source options"))
            }
            if let range = controller.trendRange {
                InputTrendSection(
                    overview: controller.overview, buckets: controller.trend,
                    range: range, resolution: $controller.trendResolution,
                    limited: controller.trendRangeIsLimited, onQuery: query
                )
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
                .contextMenu {
                    Button(localized("Name this key or shortcut…")) {
                        editKeyAlias(count.name)
                    }
                }
            }
            .frame(minHeight: 95, idealHeight: 150)
            if !controller.selectedKeyName.isEmpty {
                HStack {
                    Text("\(localized("Selected key")): \(readableEvent(controller.selectedKeyName))")
                    Button(localized("Show all keys")) {
                        controller.selectedKeyName = ""
                        query()
                    }
                    Button(localized("Name this key or shortcut…")) {
                        editKeyAlias(controller.selectedKeyName)
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
        .alert(localized("Name this key or shortcut…"), isPresented: $showingKeyAliasEditor) {
            TextField(localized("Custom display name"), text: $keyAliasDraft)
            if let editingKeyAlias, keyAliases[editingKeyAlias] != nil {
                Button(localized("Reset name")) { saveKeyAlias("") }
            }
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Save")) { saveKeyAlias(keyAliasDraft) }
        } message: {
            Text(localized("This changes only the label shown in Nexus. It does not remap any key or claim a shortcut action was executed."))
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

    private func editKeyAlias(_ name: String) {
        editingKeyAlias = name
        keyAliasDraft = keyAliases[name] ?? ""
        showingKeyAliasEditor = true
    }

    private func saveKeyAlias(_ input: String) {
        guard let editingKeyAlias else { return }
        let value = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return }
        var aliases = keyAliases
        aliases[editingKeyAlias] = value.isEmpty ? nil : value
        if let data = try? JSONEncoder().encode(aliases) { keyAliasData = data }
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

    private func readablePhysicalKey(_ name: String, shifted: Bool) -> String {
        let physical = name.count == 1 ? name.uppercased() : localized(name)
        guard let glyph = KeyboardLayoutLabel.glyph(for: name, shifted: shifted),
              glyph.uppercased() != physical.uppercased() else { return physical }
        return physical + " · " + glyph
    }

    private func readableEvent(_ name: String) -> String {
        if let alias = keyAliases[name], !alias.isEmpty { return alias }
        if name.count == 1 { return name.uppercased() }
        if name.first == "f", let number = Int(name.dropFirst()), (1...24).contains(number) {
            return "F\(number)"
        }
        if name.hasPrefix("shift_key_") {
            return "⇧ " + readablePhysicalKey(
                String(name.dropFirst("shift_key_".count)), shifted: true
            )
        }
        if name.hasPrefix("key_") {
            return readablePhysicalKey(String(name.dropFirst(4)), shifted: false)
        }
        let tokens = name.split(separator: "_").map(String.init)
        let modifierSymbols = ["control":"⌃", "option":"⌥", "command":"⌘", "shift":"⇧", "fn":"Fn"]
        if tokens.count > 1, modifierSymbols[tokens[0]] != nil {
            let modifiers = tokens.prefix(while: { modifierSymbols[$0] != nil })
            let remainder = tokens.dropFirst(modifiers.count).joined(separator: "_")
            if !remainder.isEmpty {
                let label = KeyboardEventClassifier.physicalKeys.values.contains(remainder)
                    ? readablePhysicalKey(remainder, shifted: modifiers.contains("shift"))
                    : readableEvent(remainder)
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

struct InputTrendDisplayData {
    let buckets: [InputTrendBucket]
    let resolution: InputTrendResolution
    let visibleCategories: Set<String>

    var visible: [InputTrendBucket] {
        buckets.filter { visibleCategories.contains($0.category) && $0.count > 0 }
    }

    var starts: [Int64] { Array(Set(visible.map(\.startMS))).sorted() }

    func details(at startMS: Int64) -> [InputTrendBucket] {
        visible.filter { $0.startMS == startMS }.sorted { $0.category < $1.category }
    }

    func total(at startMS: Int64) -> Int64 {
        details(at: startMS).reduce(0) { $0 + $1.count }
    }

    func total(for category: String) -> Int64 {
        buckets.filter { $0.category == category }.reduce(0) { $0 + $1.count }
    }

    func nearestStart(to x: CGFloat, maximumDistance: CGFloat = 28,
                      position: (Int64) -> CGFloat?) -> Int64? {
        starts.compactMap { start -> (Int64, CGFloat)? in
            position(start).map { (start, abs($0 - x)) }
        }
        .min { $0.1 < $1.1 }
        .flatMap { $0.1 <= maximumDistance ? $0.0 : nil }
    }

    func domain(in full: ClosedRange<Date>, focused: Bool) -> ClosedRange<Date> {
        guard focused, let first = starts.first, let last = starts.last else { return full }
        let step = bucketEnd(after: first) - first
        let span = max(last - first, step * 4)
        let padding = max(step, span / 12)
        let lower = max(Int64(full.lowerBound.timeIntervalSince1970 * 1000), first - padding)
        let upper = min(Int64(full.upperBound.timeIntervalSince1970 * 1000), last + padding)
        guard lower < upper else { return full }
        return Date(timeIntervalSince1970: Double(lower) / 1000)
            ... Date(timeIntervalSince1970: Double(upper) / 1000)
    }

    func bucketEnd(after startMS: Int64) -> Int64 {
        let date = Date(timeIntervalSince1970: Double(startMS) / 1000)
        let next = InputTrendResolution.bucketCalendar.date(
            byAdding: resolution.calendarComponent, value: 1, to: date
        ) ?? date.addingTimeInterval(1)
        return Int64(next.timeIntervalSince1970 * 1000)
    }

    /// Each run only joins adjacent UTC buckets. An unrecorded gap is never drawn as activity.
    func runs(for category: String) -> [[InputTrendBucket]] {
        let sorted = visible.filter { $0.category == category }.sorted { $0.startMS < $1.startMS }
        var result: [[InputTrendBucket]] = []
        for bucket in sorted {
            if let previous = result.last?.last, bucket.startMS == bucketEnd(after: previous.startMS) {
                result[result.count - 1].append(bucket)
            } else {
                result.append([bucket])
            }
        }
        return result
    }
}

struct InputTrendSection: View {
    @Environment(\.locale) private var locale
    let overview: InputStatisticsOverview
    let buckets: [InputTrendBucket]
    let range: ClosedRange<Date>
    @Binding var resolution: InputTrendResolution
    let limited: Bool
    let onQuery: () -> Void

    @State private var mode = "all"
    #if DEBUG
    @State private var hidden: Set<String> = CommandLine.arguments.contains("--nexus-preview-filter")
        ? ["ordinary"] : []
    #else
    @State private var hidden = Set<String>()
    #endif
    @State private var focused = true
    @State private var hoveredStartMS: Int64?
    @State private var hoveredChart: String?
    @State private var hoverX: CGFloat = 0

    private let keyboardCategories = ["ordinary", "keyboard", "modifier", "system", "shortcut"]
    private let mouseCategories = ["mouse", "scroll"]

    private var categories: [String] {
        switch mode {
        case "keyboard": keyboardCategories
        case "mouse": mouseCategories
        default: keyboardCategories + mouseCategories
        }
    }

    private var display: InputTrendDisplayData {
        InputTrendDisplayData(
            buckets: buckets, resolution: resolution,
            visibleCategories: Set(categories).subtracting(hidden)
        )
    }

    private var domainDisplay: InputTrendDisplayData {
        InputTrendDisplayData(buckets: buckets, resolution: resolution,
                              visibleCategories: Set(categories))
    }

    private var primary: [String] { categories.filter { $0 != "scroll" && !hidden.contains($0) } }
    private var scrollVisible: Bool { categories.contains("scroll") && !hidden.contains("scroll") }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary
            Divider()
            controls
            if limited {
                Label(localized(resolution == .second
                    ? "This chart shows the last 15 minutes of the selected range."
                    : "This chart shows the last 48 hours of the selected range."),
                    systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resolution == .second && buckets.contains(where: { $0.category == "ordinary" }) {
                Text(localized("Ordinary typing is counted by minute."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if display.visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text(localized("No input events in this chart range"))
                        .font(.subheadline.weight(.medium))
                    Text(localized("Try a wider time range or enable a category."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                if !primary.isEmpty && display.visible.contains(where: { $0.category != "scroll" }) {
                    chartHeading(localized("Input activity"), detail: localized("Events per interval"))
                    trendChart(categories: primary, chartID: "primary", height: 208)
                }
                if scrollVisible && display.visible.contains(where: { $0.category == "scroll" }) {
                    chartHeading(localized("Scroll events"), detail: localized("Independent scale"))
                    trendChart(categories: ["scroll"], chartID: "scroll", height: 104)
                }
            }
            if categories.contains(where: { display.total(for: $0) > 0 }) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(localized("Categories")).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(categories.filter { display.total(for: $0) > 0 }, id: \.self) { category in
                            legendItem(category)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: mode) { _ in hoveredStartMS = nil }
        .onChange(of: hidden) { _ in hoveredStartMS = nil }
        .onChange(of: focused) { _ in hoveredStartMS = nil }
        .onChange(of: resolution) { _ in hoveredStartMS = nil }
        .onChange(of: range) { _ in hoveredStartMS = nil }
        #if DEBUG
        .onAppear {
            if CommandLine.arguments.contains("--nexus-preview-hover") {
                hoveredStartMS = display.starts.first
                hoveredChart = "primary"
                hoverX = 130
            }
        }
        #endif
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                title
                Spacer(minLength: 12)
                resolutionPicker
            }
            VStack(alignment: .leading, spacing: 10) {
                title
                resolutionPicker
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(localized("Time trend")).font(.title3.weight(.semibold))
            Text(localized("Selected time range")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resolutionPicker: some View {
        Picker(localized("Resolution"), selection: $resolution) {
            Text(localized("Per second")).tag(InputTrendResolution.second)
            Text(localized("Per minute")).tag(InputTrendResolution.minute)
            Text(localized("Hourly")).tag(InputTrendResolution.hour)
            Text(localized("Daily")).tag(InputTrendResolution.day)
            Text(localized("Weekly")).tag(InputTrendResolution.week)
            Text(localized("Monthly")).tag(InputTrendResolution.month)
        }
        .frame(maxWidth: 170)
        .controlSize(.small)
        .onChange(of: resolution) { _ in onQuery() }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            summaryItem(localized("Total events"),
                        overview.keyboard + overview.mouse + overview.shortcuts + overview.scrolls)
            summaryItem(localized("Keyboard events"), overview.keyboard + overview.shortcuts)
            summaryItem(localized("Mouse events"), overview.mouse)
            summaryItem(localized("Scroll events"), overview.scrolls)
        }
    }

    private func summaryItem(_ title: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(count.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { modePicker; Spacer(minLength: 6); rangePicker; timeZoneLabel }
            VStack(alignment: .leading, spacing: 9) {
                modePicker
                HStack(spacing: 12) { rangePicker; Spacer(minLength: 0); timeZoneLabel }
            }
        }
    }

    private var modePicker: some View {
        Picker(localized("Chart focus"), selection: $mode) {
            Text(localized("Overview")).tag("all")
            Text(localized("Keyboard")).tag("keyboard")
            Text(localized("Mouse")).tag("mouse")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 270)
        .controlSize(.small)
    }

    private var rangePicker: some View {
        HStack(spacing: 7) {
            Text(localized("Chart range")).font(.caption)
                .fixedSize(horizontal: true, vertical: false)
            Picker("", selection: $focused) {
                Text(localized("Focus on data")).tag(true)
                Text(localized("Full range")).tag(false)
            }
            .labelsHidden()
            .frame(width: 130)
            .controlSize(.small)
        }
    }

    private var timeZoneLabel: some View {
        let startZone = TimeZone.current.abbreviation(for: range.lowerBound)
            ?? TimeZone.current.identifier
        let endZone = TimeZone.current.abbreviation(for: range.upperBound)
            ?? TimeZone.current.identifier
        let zone = startZone == endZone ? startZone : "\(startZone)/\(endZone)"
        return Text("\(localized("Local time")) · \(zone)")
            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
    }

    private func chartHeading(_ name: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.subheadline.weight(.medium))
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legendItem(_ category: String) -> some View {
        let isHidden = hidden.contains(category)
        return Button {
            if isHidden { hidden.remove(category) } else { hidden.insert(category) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color(for: category)).frame(width: 7, height: 7)
                Text(categoryLabel(category)).lineLimit(1)
                Spacer(minLength: 2)
                Text(display.total(for: category).formatted())
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            .opacity(isHidden ? 0.38 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(categoryLabel(category)), \(display.total(for: category).formatted())")
        .accessibilityAddTraits(isHidden ? [] : [.isSelected])
    }

    private func color(for category: String) -> Color {
        switch category {
        case "ordinary": Color(red: 0.29, green: 0.49, blue: 0.73)
        case "keyboard": Color(red: 0.25, green: 0.68, blue: 0.76)
        case "modifier": Color(red: 0.57, green: 0.49, blue: 0.74)
        case "system": Color(red: 0.77, green: 0.58, blue: 0.33)
        case "shortcut": Color(red: 0.40, green: 0.64, blue: 0.45)
        case "mouse": Color(red: 0.83, green: 0.46, blue: 0.44)
        default: Color(red: 0.58, green: 0.47, blue: 0.72)
        }
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "ordinary": localized("Typing")
        case "keyboard": localized("Function keys")
        case "modifier": localized("Modifier keys")
        case "system": localized("System keys")
        case "shortcut": localized("Shortcuts")
        case "mouse": localized("Mouse clicks")
        default: localized("Scrolling")
        }
    }

    private func trendChart(categories plotted: [String], chartID: String,
                            height: CGFloat) -> some View {
        let data = display
        let domain = domainDisplay.domain(in: range, focused: focused)
        let peak = max(1, data.visible.filter { plotted.contains($0.category) }.map(\.count).max() ?? 1)
        let ceiling = Double(peak) * 1.12
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing) {
                Text(peak.formatted(.number.notation(.compactName)))
                Spacer()
                Text("0")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 42, height: height - 23, alignment: .trailing)
            GeometryReader { geometry in
                Chart {
                    RuleMark(y: .value(localized("Count"), Double(peak) / 2))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.18))
                    ForEach(plotted, id: \.self) { category in
                        ForEach(Array(data.runs(for: category).enumerated()), id: \.offset) { index, run in
                            if data.starts.count <= 12 {
                                ForEach(run) { bucket in
                                    BarMark(
                                        x: .value(localized("Time"), date(for: bucket.startMS)),
                                        y: .value(localized("Count"), bucket.count),
                                        width: .fixed(3)
                                    )
                                    .position(by: .value(localized("Category"), category))
                                    .cornerRadius(2)
                                    .foregroundStyle(color(for: category).opacity(0.58))
                                }
                            }
                            if run.count > 1 {
                                ForEach(run) { bucket in
                                    LineMark(
                                        x: .value(localized("Time"), date(for: bucket.startMS)),
                                        y: .value(localized("Count"), bucket.count),
                                        series: .value(localized("Category"), "\(category)-\(index)")
                                    )
                                    .interpolationMethod(.linear)
                                    .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round))
                                    .foregroundStyle(color(for: category))
                                }
                            }
                            if data.starts.count <= 80 || run.count == 1 {
                                ForEach(run) { bucket in
                                    PointMark(
                                        x: .value(localized("Time"), date(for: bucket.startMS)),
                                        y: .value(localized("Count"), bucket.count)
                                    )
                                    .symbolSize(26)
                                    .foregroundStyle(color(for: category))
                                }
                            }
                        }
                    }
                    if let hoveredStartMS, data.details(at: hoveredStartMS).contains(where: { plotted.contains($0.category) }) {
                        RuleMark(x: .value(localized("Time"), date(for: hoveredStartMS)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(.secondary)
                        ForEach(data.details(at: hoveredStartMS).filter { plotted.contains($0.category) }) { bucket in
                            PointMark(
                                x: .value(localized("Time"), date(for: bucket.startMS)),
                                y: .value(localized("Count"), bucket.count)
                            )
                            .symbolSize(70)
                            .foregroundStyle(color(for: bucket.category))
                        }
                    }
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: 0...ceiling)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: axisTicks(in: domain, width: geometry.size.width)) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                            .foregroundStyle(Color.gray.opacity(0.12))
                        AxisValueLabel(format: axisFormat(for: domain).locale(locale))
                            .font(.caption2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { chartGeometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let point) = phase else {
                                    hoveredStartMS = nil
                                    hoveredChart = nil
                                    return
                                }
                                let plot = chartGeometry[proxy.plotAreaFrame]
                                guard plot.contains(point),
                                      let _: Date = proxy.value(atX: point.x - plot.minX) else {
                                    hoveredStartMS = nil
                                    hoveredChart = nil
                                    return
                                }
                                let nearest = data.nearestStart(to: point.x - plot.minX) { start in
                                    proxy.position(forX: self.date(for: start))
                                }
                                guard let nearest,
                                      data.details(at: nearest).contains(where: { plotted.contains($0.category) }),
                                      let position = proxy.position(forX: self.date(for: nearest)) else {
                                    hoveredStartMS = nil
                                    hoveredChart = nil
                                    return
                                }
                                hoveredStartMS = nearest
                                hoveredChart = chartID
                                hoverX = plot.minX + position
                            }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hoveredChart == chartID, let hoveredStartMS,
                       data.details(at: hoveredStartMS).contains(where: { plotted.contains($0.category) }) {
                        hoverCard(startMS: hoveredStartMS)
                            .frame(width: min(218, geometry.size.width - 8), alignment: .leading)
                            .offset(
                                x: max(0, min(geometry.size.width - 222, hoverX + 12)),
                                y: min(5, height - CGFloat(70 + 20 * data.details(at: hoveredStartMS).count))
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }

    private func axisFormat(for domain: ClosedRange<Date>) -> Date.FormatStyle {
        switch resolution {
        case .second: .dateTime.hour().minute().second()
        case .minute, .hour:
            domain.upperBound.timeIntervalSince(domain.lowerBound) < 86_400
                ? .dateTime.hour().minute()
                : .dateTime.month(.abbreviated).day().hour()
        case .day, .week: .dateTime.month(.abbreviated).day()
        case .month: .dateTime.year().month(.abbreviated)
        }
    }

    private func axisTicks(in domain: ClosedRange<Date>, width: CGFloat) -> [Date] {
        let count = width < 480 ? 3 : 5
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let calendar = InputTrendResolution.bucketCalendar
        return Array(Set((1...count).compactMap { position -> Date? in
            let approximate = domain.lowerBound.addingTimeInterval(
                span * Double(position) / Double(count + 1)
            )
            return calendar.dateInterval(of: resolution.calendarComponent, for: approximate)?.start
        })).sorted()
    }

    private func date(for ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private func hoverCard(startMS: Int64) -> some View {
        let details = display.details(at: startMS)
        let startDate = date(for: startMS)
        let endDate = date(for: display.bucketEnd(after: startMS))
        let zone = TimeZone.current.abbreviation(for: startDate) ?? TimeZone.current.identifier
        return VStack(alignment: .leading, spacing: 5) {
            Text(startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
                 + " – " + endDate.formatted(.dateTime.hour().minute().locale(locale)) + " " + zone)
                .font(.caption2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(localized("Total events"))
                Spacer()
                Text(details.reduce(Int64(0)) { $0 + $1.count }.formatted()).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            Divider()
            ForEach(details) { bucket in
                HStack(spacing: 6) {
                    Circle().fill(color(for: bucket.category)).frame(width: 6, height: 6)
                    Text(categoryLabel(bucket.category)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(bucket.count.formatted()).monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.13), radius: 10, y: 4)
    }
}

#if DEBUG
/// A real macOS window with deterministic chart fixtures for visual review.
struct InputTrendPreviewApp: App {
    var body: some Scene {
        WindowGroup(localized("Time trend")) {
            InputTrendPreviewView()
        }
        .defaultSize(
            width: CommandLine.arguments.contains("--nexus-preview-small") ? 440 : 940,
            height: 760
        )
    }
}

private struct InputTrendPreviewView: View {
    @State private var resolution: InputTrendResolution = .hour
    private let scenario = CommandLine.arguments.first { $0.hasPrefix("--nexus-preview-scenario=") }?
        .split(separator: "=").last.map(String.init) ?? "sparse"
    private let language = CommandLine.arguments.first { $0.hasPrefix("--nexus-preview-language=") }?
        .split(separator: "=").last.map(String.init) ?? "en"

    private var startMS: Int64 { 1_795_392_000_000 } // 2026-11-23 00:00 UTC
    private var endMS: Int64 { startMS + (scenario == "dense" ? 48 : 24) * 3_600_000 }

    private var buckets: [InputTrendBucket] {
        switch scenario {
        case "empty": []
        case "dense":
            (0..<48).flatMap { hour -> [InputTrendBucket] in
                let time = startMS + Int64(hour) * 3_600_000
                return [
                    .init(startMS: time, category: "ordinary", count: Int64(17 + (hour * 7) % 49)),
                    .init(startMS: time, category: "shortcut", count: Int64(2 + hour % 8)),
                    .init(startMS: time, category: "mouse", count: Int64(8 + (hour * 3) % 27)),
                    .init(startMS: time, category: "scroll", count: Int64(11 + (hour * 11) % 64)),
                ]
            }
        case "scroll":
            [
                .init(startMS: startMS + 4 * 3_600_000, category: "ordinary", count: 7),
                .init(startMS: startMS + 5 * 3_600_000, category: "ordinary", count: 12),
                .init(startMS: startMS + 6 * 3_600_000, category: "mouse", count: 4),
                .init(startMS: startMS + 4 * 3_600_000, category: "scroll", count: 2_400),
                .init(startMS: startMS + 5 * 3_600_000, category: "scroll", count: 5_200),
                .init(startMS: startMS + 6 * 3_600_000, category: "scroll", count: 3_100),
            ]
        default:
            [
                .init(startMS: startMS + 3 * 3_600_000, category: "ordinary", count: 12),
                .init(startMS: startMS + 3 * 3_600_000, category: "mouse", count: 3),
                .init(startMS: startMS + 9 * 3_600_000, category: "shortcut", count: 2),
                .init(startMS: startMS + 18 * 3_600_000, category: "ordinary", count: 8),
                .init(startMS: startMS + 18 * 3_600_000, category: "scroll", count: 47),
            ]
        }
    }

    private var overview: InputStatisticsOverview {
        func total(_ category: String) -> Int64 {
            buckets.filter { $0.category == category }.reduce(0) { $0 + $1.count }
        }
        return InputStatisticsOverview(
            keyboard: total("ordinary") + total("keyboard") + total("modifier") + total("system"),
            mouse: total("mouse"), specialKeys: 0, shortcuts: total("shortcut"),
            scrolls: total("scroll"), firstEventMS: buckets.map(\.startMS).min()
        )
    }

    var body: some View {
        ScrollView {
            InputTrendSection(
                overview: overview, buckets: buckets,
                range: Date(timeIntervalSince1970: Double(startMS) / 1000)
                    ... Date(timeIntervalSince1970: Double(endMS) / 1000),
                resolution: $resolution, limited: false, onQuery: {}
            )
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 420, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: language))
        .preferredColorScheme(CommandLine.arguments.contains("--nexus-preview-dark") ? .dark : .light)
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
#endif
