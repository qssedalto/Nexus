import Foundation

public struct PathCopyAction: Sendable {
    private let formatter: PathFormatter
    private let clipboardWriter: ClipboardWriting
    private let historyStore: AppSettingsStore?
    private let operationStore: OperationStore?

    public init(
        formatter: PathFormatter = PathFormatter(),
        clipboardWriter: ClipboardWriting,
        historyStore: AppSettingsStore? = nil,
        operationStore: OperationStore? = nil
    ) {
        self.formatter = formatter
        self.clipboardWriter = clipboardWriter
        self.historyStore = historyStore
        self.operationStore = operationStore
    }

    @discardableResult
    public func copy(urls: [URL], as format: PathFormat) throws -> String? {
        guard !urls.isEmpty else {
            return nil
        }

        let eventTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
        let output = formatter.format(urls: urls, as: format)
        try clipboardWriter.writeString(output)
        let completedTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
        historyStore?.addHistoryEntry(output)
        if let operationStore {
            Task.detached(priority: .utility) {
                try? operationStore.record(type: "path_copy", urls: urls, sourceApplication: "Finder", detectionMethod: "finder_sync", eventTimeMS: eventTimeMS, completedTimeMS: completedTimeMS, clipboardText: output)
            }
        }
        return output
    }
}
