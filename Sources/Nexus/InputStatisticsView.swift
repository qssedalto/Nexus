import AppKit
import CoreGraphics
import SwiftUI
import NexusCore

@MainActor
final class InputStatisticsController: ObservableObject {
    static let shared = InputStatisticsController()
    @Published private(set) var counts: [InputCount] = []
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
        counts = (try? store?.counts(from: startMS, to: endMS)) ?? []
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
            let rows = try store?.counts(from: 0, to: Int64.max) ?? []
            let csv = "name,count\n" + rows.map { "\($0.name),\($0.count)" }.joined(separator: "\n") + "\n"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.permissionGranted ? localized("Input permission granted") : localized("Input permission required"))
                Spacer()
                if !controller.permissionGranted { Button(localized("Grant input permission")) { controller.requestPermission() } }
            }
            Toggle(localized("Pause statistics"), isOn: $controller.paused)
            HStack {
                DatePicker(localized("From"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $startSecond, format: .number).frame(width: 34)
                TextField("ms", value: $startMS, format: .number).frame(width: 44)
                DatePicker(localized("To"), selection: $end, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $endSecond, format: .number).frame(width: 34)
                TextField("ms", value: $endMS, format: .number).frame(width: 44)
                Button(localized("Query"), action: query)
            }.font(.caption)
            List(controller.counts) { count in
                HStack {
                    Text(count.name)
                    Spacer()
                    Text(count.count.formatted()).monospacedDigit()
                }
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
        .onAppear { controller.startIfPermitted(); query() }
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
