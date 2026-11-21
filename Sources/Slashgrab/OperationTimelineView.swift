import SwiftUI
import SlashgrabCore

struct OperationTimelineView: View {
    @ObservedObject var appState: AppState
    @State private var start = Date().addingTimeInterval(-86400)
    @State private var end = Date()
    @State private var startMillisecond = 0
    @State private var endMillisecond = 999
    @State private var startSecond = 0
    @State private var endSecond = 59
    @State private var search = ""
    @State private var operationType = "All"
    @State private var itemKind = "All"
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
            }
            .font(.caption)
            TextField(localized("Search history"), text: $search)
            Picker(localized("Operation"), selection: $operationType) {
                Text(localized("All")).tag("All")
                Text(localized("File copy")).tag("copy")
                Text(localized("Path copy")).tag("path_copy")
                Text(localized("Drag/drop copy")).tag("drop_copy")
                Text(localized("Text copy")).tag("text_copy")
                Text(localized("Image copy")).tag("image_copy")
                Text(localized("Paste request")).tag("paste_request")
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
            List(visible) { operation in
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
                        Text(localized(operation.type == "drop_copy" ? "Drag/drop copy" : operation.type == "paste_request" ? "Paste request" : operation.type == "text_copy" ? "Text copy" : operation.type == "image_copy" ? "Image copy" : operation.type == "copy" ? "File copy" : "Path copy"))
                        Text(operation.type == "paste_request"
                             ? localized("Paste requested, completion unknown")
                             : operation.type == "text_copy" ? (operation.clipboardText ?? localized("Text"))
                             : (operation.items.count == 1 ? operation.items[0].name
                                : "\(operation.items.count) \(localized("items"))"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .onAppear { query() }
        .onDisappear { folderSizeTask?.cancel() }
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
        guard lower <= upper else { return }
        appState.refreshOperations(from: lower, to: upper == Int64.max ? upper : upper + 1)
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
