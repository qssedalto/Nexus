import AppKit
import Charts
import CoreGraphics
import SwiftUI
import SlashgrabCore

@MainActor
final class InputStatisticsController: ObservableObject {
    static let shared = InputStatisticsController()
    @Published private(set) var counts: [InputCount] = []
    @Published private(set) var categoryCounts: [InputCategoryCount] = []
    @Published private(set) var overview = InputStatisticsOverview(
        keyboard: 0, mouse: 0, specialKeys: 0, shortcuts: 0,
        scrolls: 0, firstEventMS: nil)
    @Published private(set) var trend: [InputTrendBucket] = []
    @Published var trendResolution: InputTrendResolution = .day
    @Published var selectedCategory = ""
    @Published var selectedKeyName = ""
    @Published private(set) var permissionGranted = false
    @Published var paused: Bool {
        didSet {
            UserDefaults.standard.set(paused, forKey: "nexusInputPaused")
            if paused { monitor?.stop() } else { startIfPermitted() }
        }
    }
    @Published private(set) var dataStatus = ""
    private let store = InputStatisticsStore.shared()
    private var monitor: InputMonitor?
    private var permissionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
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

    func startIfPermitted() {
        permissionGranted = monitor?.hasPermission ?? false
        if permissionGranted && !paused { _ = monitor?.start() }
    }

    func requestPermission() {
        permissionGranted = CGRequestListenEventAccess()
        if permissionGranted && !paused { _ = monitor?.start() }
    }

    func refresh(from startMS: Int64, to endMS: Int64) {
        guard startMS >= 0, endMS > startMS, let store else {
            dataStatus = localized("Invalid time range")
            return
        }
        do {
            counts = try store.counts(from: startMS, to: endMS)
            categoryCounts = try store.categoryCounts(from: startMS, to: endMS)
            overview = try store.overview(from: startMS, to: endMS)
            trend = try store.trend(from: startMS, to: endMS,
                                    resolution: trendResolution,
                                    category: selectedCategory.isEmpty ? nil : selectedCategory,
                                    name: selectedKeyName.isEmpty ? nil : selectedKeyName)
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
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Date()
    @State private var startSecond = 0
    @State private var endSecond = 59
    @State private var startMS = 0
    @State private var endMS = 999
    @State private var deleteConfirmation = 0
    @State private var showingDeleteAlert = false
    @State private var selectedPreset = "today"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.permissionGranted ? localized("Input permission granted") : localized("Input permission required"))
                Spacer()
                if !controller.permissionGranted { Button(localized("Grant input permission")) { controller.requestPermission() } }
            }
            Toggle(localized("Pause statistics"), isOn: $controller.paused)
            Toggle(localized("Count held-key repeats"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "nexusCountKeyRepeats") },
                set: { UserDefaults.standard.set($0, forKey: "nexusCountKeyRepeats") }
            ))
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
            HStack {
                DatePicker(localized("From"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $startSecond, format: .number).frame(width: 34)
                TextField("ms", value: $startMS, format: .number).frame(width: 44)
                DatePicker(localized("To"), selection: $end, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $endSecond, format: .number).frame(width: 34)
                TextField("ms", value: $endMS, format: .number).frame(width: 44)
                Button(localized("Query"), action: query)
            }.font(.caption)
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
                        Text(count.name)
                        Text(count.category).foregroundStyle(.secondary).font(.caption)
                        Spacer()
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
            HStack {
                Button(localized("Export CSV")) { controller.exportCSV() }
                Button(localized("Check database")) { controller.checkIntegrity() }
                Button(localized("Backup database")) { controller.backup() }
                Button(localized("Delete selected range")) {
                    deleteConfirmation = 1
                    showingDeleteAlert = true
                }
            }
            Text("\(localized("Database size")): \(controller.databaseSizeBytes.formatted()) B · \(controller.dataStatus)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { controller.startIfPermitted(); applyPreset() }
        .alert("\(localized("Confirm deletion")) \(deleteConfirmation)/5", isPresented: $showingDeleteAlert) {
            Button(localized("Cancel"), role: .cancel) { deleteConfirmation = 0 }
            Button(localized("Confirm"), role: .destructive) {
                if deleteConfirmation == 5 {
                    let (lower, upper) = bounds
                    controller.delete(from: lower, to: upper)
                    deleteConfirmation = 0
                } else {
                    deleteConfirmation += 1
                    DispatchQueue.main.async { showingDeleteAlert = true }
                }
            }
        } message: {
            Text(localized("This deletes statistics in the selected time range."))
        }
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
