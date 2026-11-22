import AppKit
import Charts
import CoreGraphics
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
    @Published var trendResolution: InputTrendResolution = .day
    @Published var selectedCategory = ""
    @Published var selectedKeyName = ""
    @Published private(set) var permissionGranted = false
    /// Defaults to on for existing users but remains under their control.
    /// Turning this off stops the event tap and related diagnostics.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "nexusInputStatisticsEnabled")
            if enabled { startIfPermitted() }
            else {
                diagnosticsEnabled = false
                monitor?.stop()
            }
        }
    }
    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "nexusInputPaused")
            if paused { monitor?.stop() } else { startIfPermitted() }
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
                let granted = self.monitor?.hasPermission ?? false
                if !granted { self.monitor?.stop() }
                self.permissionGranted = granted
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startIfPermitted() }
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
                guard let self, self.diagnosticsEnabled else { return }
                self.diagnosticEvents.insert(record, at: 0)
                if self.diagnosticEvents.count > 25 {
                    self.diagnosticEvents.removeLast()
                }
            }
        }
    }

    func setPasteRequestHandler(_ handler: @escaping @Sendable (Int64) -> Void) {
        monitor?.onPasteRequest = handler
    }

    func startIfPermitted() {
        permissionGranted = monitor?.hasPermission ?? false
        if PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: enabled, paused: paused, permissionGranted: permissionGranted
        ) {
            _ = monitor?.start()
        } else {
            monitor?.stop()
        }
    }

    func requestPermission() {
        permissionGranted = CGRequestListenEventAccess()
        startIfPermitted()
    }

    func refresh(from startMS: Int64, to endMS: Int64) {
        guard startMS >= 0, endMS > startMS, let store else {
            dataStatus = localized("Invalid time range")
            return
        }
        do {
            let source = selectedSource.isEmpty ? nil : selectedSource
            counts = try store.counts(from: startMS, to: endMS)
            sourceCounts = try store.sourceCounts(from: startMS, to: endMS)
            categoryCounts = try store.categoryCounts(from: startMS, to: endMS, source: source)
            overview = try store.overview(from: startMS, to: endMS, source: source)
            trend = try store.trend(from: startMS, to: endMS,
                                    resolution: trendResolution,
                                    category: selectedCategory.isEmpty ? nil : selectedCategory,
                                    name: selectedKeyName.isEmpty ? nil : selectedKeyName,
                                    source: source)
            dataStatus = localized("Statistics query complete")
        } catch {
            dataStatus = error.localizedDescription
        }
        permissionGranted = monitor?.hasPermission ?? false
        if !permissionGranted { monitor?.stop() }
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

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.permissionGranted ? localized("Input permission granted") : localized("Input permission required"))
                Spacer()
                if !controller.permissionGranted { Button(localized("Grant input permission")) { controller.requestPermission() } }
            }
            Toggle(localized("Enable keyboard and mouse statistics"), isOn: $controller.enabled)
            Toggle(localized("Pause statistics"), isOn: $controller.paused)
                .disabled(!controller.enabled)
            Toggle(localized("Count held-key repeats"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "nexusCountKeyRepeats") },
                set: { UserDefaults.standard.set($0, forKey: "nexusCountKeyRepeats") }
            ))
                .disabled(!controller.enabled)
            Picker(localized("Time range"), selection: $selectedPreset) {
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
                    ForEach(Array(Set(controller.sourceCounts.map(\.source))).sorted(), id: \.self) { source in
                        Text(readableSource(source)).tag(source)
                    }
                }
                .onChange(of: controller.selectedSource) { _ in query() }
                Button(localized("Reset source filter")) {
                    controller.selectedSource = ""
                    query()
                }
                .disabled(controller.selectedSource.isEmpty)
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
                    Text(localized("Hourly")).tag(InputTrendResolution.hour)
                    Text(localized("Daily")).tag(InputTrendResolution.day)
                    Text(localized("Weekly")).tag(InputTrendResolution.week)
                    Text(localized("Monthly")).tag(InputTrendResolution.month)
                }
                .frame(width: 120)
                .onChange(of: controller.trendResolution) { _ in query() }
            }
            Chart(controller.trend) { bucket in
                BarMark(
                    x: .value(localized("Time"), Date(timeIntervalSince1970: TimeInterval(bucket.startMS) / 1000)),
                    y: .value(localized("Count"), bucket.count)
                )
                .foregroundStyle(by: .value(localized("Category"), bucket.category))
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 165)
            HStack {
                Text(localized("Key and shortcut ranking")).font(.headline)
                Spacer()
                Picker(localized("Event category"), selection: $controller.selectedCategory) {
                    Text(localized("All")).tag("")
                    ForEach(["keyboard","modifier","system","shortcut","mouse","scroll","ordinary"], id: \.self) { category in
                        Text(localized(category)).tag(category)
                    }
                }
                .frame(width: 150)
                .onChange(of: controller.selectedCategory) { _ in
                    controller.selectedKeyName = ""
                    query()
                }
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
                        Label(count.name, systemImage: icon(for: count.name))
                        Text(count.category).foregroundStyle(.secondary).font(.caption)
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
                    Text("\(localized("Selected key")): \(controller.selectedKeyName)")
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
                            Text(item.category).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(item.count.formatted()).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
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
                        HStack {
                            Label(event.name, systemImage: icon(for: event.name))
                            Text(event.source).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(event.supported ? localized("Recognized") : localized("Unknown / unsupported"))
                                .font(.caption2)
                            Text(Date(timeIntervalSince1970: TimeInterval(event.timeMS) / 1000)
                                .formatted(date: .omitted, time: .complete))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .frame(height: 130)
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
        .onAppear { controller.startIfPermitted(); applyPreset() }
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

    private func readableSource(_ source: String) -> String {
        if source.hasPrefix("iohid_") {
            return source
                .replacingOccurrences(of: "iohid_consumer:", with: "HID media · ")
                .replacingOccurrences(of: "iohid_function:", with: "HID function · ")
                .replacingOccurrences(of: "_", with: " ")
        }
        return "\(source) · \(localized("Device unknown"))"
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
