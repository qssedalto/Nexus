import SwiftUI
import NexusCore

struct OperationTimelineView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @State private var start = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    @State private var end = Date()
    @State private var startMillisecond = 0
    @State private var endMillisecond = 999
    @State private var startSecond = 0
    @State private var endSecond = 59
    @State private var search = ""
    @State private var operationType = "All"
    @State private var itemKind = "All"
    @State private var rangeError = false
    @State private var hasLoadedTimeline = false
    @State private var showingAllHistory = false
    @State private var sizeStatus: String?
    @State private var activeSizeItem: String?
    @State private var folderSizeTask: Task<Void, Never>?
    @State private var sizeScanID = UUID()

    private var visible: [RecordedOperation] {
        appState.operations.filter { operation in
            (operationType == "All" || operation.type == operationType) &&
            (itemKind == "All" || operation.items.contains { $0.kind == itemKind }) &&
            (search.isEmpty || operation.items.contains {
                $0.name.localizedCaseInsensitiveContains(search) || ($0.source?.localizedCaseInsensitiveContains(search) ?? false)
            } || (operation.clipboardText?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DatePicker(localized("From"), selection: $start, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $startSecond, format: .number).frame(width: 35)
                TextField("ms", value: $startMillisecond, format: .number)
                    .frame(width: 48)
                DatePicker(localized("To"), selection: $end, displayedComponents: [.date, .hourAndMinute])
                TextField("ss", value: $endSecond, format: .number).frame(width: 35)
                TextField("ms", value: $endMillisecond, format: .number)
                    .frame(width: 48)
                Button(localized("Query"), action: query)
                Button(localized("All history")) {
                    rangeError = false
                    showingAllHistory = true
                    appState.refreshOperations(from: 0)
                }
            }
            .font(.caption)
            if rangeError {
                Text(localized("End time must be at or after start time"))
                    .font(.caption).foregroundStyle(.orange)
            } else if showingAllHistory {
                Text(localized("Showing all history")).font(.caption).foregroundStyle(.secondary)
            }
            if !clipboard.historyEnabled || clipboard.paused {
                HStack {
                    Text(localized(clipboard.historyEnabled
                        ? "Copy history collection is paused" : "Copy history collection is off"))
                    Button(localized(clipboard.historyEnabled ? "Resume clipboard history" : "Enable clipboard history monitoring")) {
                        if clipboard.historyEnabled { clipboard.paused = false }
                        else { clipboard.historyEnabled = true }
                    }
                }
                .font(.caption)
            } else if !clipboard.enabled && !clipboard.textEnabled && !clipboard.imageEnabled {
                Text(localized("Select file, text, or image recording in Privacy & Permissions."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField(localized("Search history"), text: $search)
            Picker(localized("Operation"), selection: $operationType) {
                Text(localized("All")).tag("All")
                Text(localized("File copy")).tag("copy")
                Text(localized("Path copy")).tag("path_copy")
                Text(localized("Drag/drop copy")).tag("drop_copy")
                Text(localized("Text copy")).tag("text_copy")
                Text(localized("Image copy")).tag("image_copy")
                Text(localized("Paste")).tag("paste_request")
            }
            Picker(localized("Item type"), selection: $itemKind) {
                Text(localized("All")).tag("All")
                Text(localized("Images")).tag("image")
                Text(localized("Folder")).tag("folder")
                Text(localized("Package")).tag("package")
                Text(localized("Document")).tag("document")
                Text(localized("Video")).tag("video")
                Text(localized("Archive")).tag("archive")
                Text(localized("Text")).tag("text")
            }
            if let sizeStatus {
                HStack {
                    Text(sizeStatus).font(.caption).foregroundStyle(.secondary)
                    if activeSizeItem != nil {
                        Button(localized("Cancel folder scan")) {
                            folderSizeTask?.cancel()
                        }
                    }
                }
            }
            if let error = appState.operationQueryError {
                Text(error).foregroundStyle(.orange)
            } else if appState.loadingOperations && appState.operations.isEmpty {
                ProgressView().controlSize(.small)
            } else if visible.isEmpty {
                Text(localized(appState.operations.isEmpty
                    ? "No operations in this time range" : "No operations match these filters"))
                    .foregroundStyle(.secondary)
            }
            List(visible) { operation in
                if operation.type == "paste_request" {
                    HStack {
                        Text(Self.timestamp(operation.eventTimeMS ?? operation.detectedTimeMS))
                            .monospacedDigit()
                        Text(localized("Paste detected"))
                    }
                } else {
                    timelineEntry(operation)
                }
            }
        }
        .padding()
        .onAppear {
            // Keep the default recent range open to new events until the user
            // runs a query with an explicit end time.
            if hasLoadedTimeline {
                appState.refreshOperations()
            } else {
                hasLoadedTimeline = true
                appState.refreshOperations(from: Int64(start.timeIntervalSince1970 * 1_000))
            }
        }
        .onChange(of: clipboard.savedRevision) { _ in appState.refreshOperations() }
        .onDisappear { folderSizeTask?.cancel() }
    }

    private func timelineEntry(_ operation: RecordedOperation) -> some View {
        DisclosureGroup {
            ForEach(Array(operation.items.enumerated()), id: \.offset) { position, item in
                VStack(alignment: .leading) {
                    Text(item.name).fontWeight(.medium)
                    HStack {
                        Text(item.source ?? localized("Unknown source"))
                            .font(.caption).textSelection(.enabled)
                        if let source = item.source {
                            Button {
                                appState.copyAgain(source)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(localized("Copy source path"))
                        }
                    }
                    Text("\(item.kind) · \(item.fileExtension ?? localized("Unknown")) · \(item.size.map(String.init) ?? localized("Unknown"))")
                        .font(.caption).foregroundStyle(.secondary)
                    if (item.kind == "folder" || item.kind == "package"),
                       let path = item.source, path.hasPrefix("/"), item.size == nil {
                        Button(localized("Calculate folder size (background)")) {
                            calculateFolderSize(operationID: operation.id, position: position, path: path)
                        }
                        .disabled(activeSizeItem != nil)
                    }
                }
            }
            Text("\(localized("Detection")): \(operation.detectionMethod)")
            Text("\(localized("Status")): \(operation.status)")
            HStack {
                Text("\(localized("Target")): \(operation.target ?? localized("Unknown"))")
                if let target = operation.target {
                    Button {
                        appState.copyAgain(target)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(localized("Copy target path"))
                }
            }
            Text("\(localized("Duration")): \(operation.durationMS.map(String.init) ?? localized("Unknown")) ms")
            if let copied = operation.clipboardText {
                Text(copied).textSelection(.enabled)
            }
        } label: {
            HStack {
                Text(Self.timestamp(operation.eventTimeMS ?? operation.detectedTimeMS))
                    .monospacedDigit()
                Text(localized(operation.type == "drop_copy" ? "Drag/drop copy" : operation.type == "text_copy" ? "Text copy" : operation.type == "image_copy" ? "Image copy" : operation.type == "copy" ? "File copy" : "Path copy"))
                Text(operation.type == "text_copy" ? (operation.clipboardText ?? localized("Text"))
                     : (operation.items.count == 1 ? operation.items[0].name
                        : "\(operation.items.count) \(localized("items"))"))
                    .lineLimit(1)
            }
        }
    }

    private func calculateFolderSize(operationID: String, position: Int, path: String) {
        folderSizeTask?.cancel()
        let requestID = UUID()
        sizeScanID = requestID
        activeSizeItem = "\(operationID):\(position)"
        sizeStatus = localized("Calculating folder size in the background…")
        folderSizeTask = Task { @MainActor in
            do {
                let url = URL(fileURLWithPath: path)
                // Structured child task inherits cancellation. No Finder
                // callback or UI actor performs a recursive file walk.
                let result = try await withThrowingTaskGroup(of: Int64.self) { group in
                    group.addTask(priority: .utility) {
                        try FolderSizeScanner.logicalSize(of: url)
                    }
                    guard let value = try await group.next() else {
                        throw FolderSizeScanner.ScanError.unavailable
                    }
                    return value
                }
                try Task<Never, Never>.checkCancellation()
                guard sizeScanID == requestID else { return }
                guard let store = OperationStore.shared(),
                      try store.updateComputedSize(operationID: operationID,
                                                   position: position,
                                                   expectedSource: path,
                                                   bytes: result) else {
                    throw FolderSizeScanner.ScanError.unavailable
                }
                appState.refreshOperations()
                sizeStatus = "\(localized("Folder size")): \(result.formatted()) B"
            } catch is CancellationError {
                if sizeScanID == requestID { sizeStatus = localized("Folder size scan cancelled") }
            } catch {
                if sizeScanID == requestID { sizeStatus = error.localizedDescription }
            }
            if sizeScanID == requestID {
                activeSizeItem = nil
                folderSizeTask = nil
            }
        }
    }

    private func query() {
        let lower = Int64(start.timeIntervalSince1970 / 60) * 60_000 + Int64(max(0, min(59, startSecond))) * 1000 + Int64(max(0, min(999, startMillisecond)))
        let upper = Int64(end.timeIntervalSince1970 / 60) * 60_000 + Int64(max(0, min(59, endSecond))) * 1000 + Int64(max(0, min(999, endMillisecond)))
        rangeError = lower > upper
        guard !rangeError else { return }
        showingAllHistory = false
        appState.refreshOperations(from: lower, to: upper == Int64.max ? upper : upper + 1)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
