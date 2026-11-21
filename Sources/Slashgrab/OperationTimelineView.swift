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

    private var visible: [RecordedOperation] {
        appState.operations.filter { operation in
            (operationType == "All" || operation.type == operationType) &&
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
                Text(localized("Text copy")).tag("text_copy")
                Text(localized("Image copy")).tag("image_copy")
            }
            List(visible) { operation in
                DisclosureGroup {
                    ForEach(Array(operation.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading) {
                            Text(item.name).fontWeight(.medium)
                            Text(item.source ?? localized("Unknown source"))
                                .font(.caption).textSelection(.enabled)
                            Text("\(item.kind) · \(item.fileExtension ?? localized("Unknown")) · \(item.size.map(String.init) ?? localized("Unknown"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(localized("Detection")): \(operation.detectionMethod)")
                    Text("\(localized("Status")): \(operation.status)")
                    Text("\(localized("Target")): \(operation.target ?? localized("Unknown"))")
                    Text("\(localized("Duration")): \(operation.durationMS.map(String.init) ?? localized("Unknown")) ms")
                    if let copied = operation.clipboardText {
                        Text(copied).textSelection(.enabled)
                    }
                } label: {
                    HStack {
                        Text(Self.timestamp(operation.eventTimeMS ?? operation.detectedTimeMS))
                            .monospacedDigit()
                        Text(localized(operation.type == "text_copy" ? "Text copy" : operation.type == "image_copy" ? "Image copy" : operation.type == "copy" ? "File copy" : "Path copy"))
                        Text(operation.type == "text_copy" ? (operation.clipboardText ?? localized("Text")) : (operation.items.count == 1 ? operation.items[0].name : "\(operation.items.count) \(localized("items"))"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .onAppear { appState.refreshOperations() }
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
