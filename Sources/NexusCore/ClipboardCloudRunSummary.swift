import Foundation

/// Privacy-safe local diagnostic for one explicitly requested sync attempt.
/// It stores only counts and a timestamp; no clipboard content, filenames,
/// source application, file paths, CloudKit credentials or server tokens.
public struct ClipboardCloudRunSummary: Codable, Sendable, Equatable {
    public let finishedTimeMS: Int64
    public let uploaded: Int
    public let downloaded: Int
    public let pending: Int
    public let moreComing: Bool
    public let localHistoryInspected: Int?

    public init?(report: ClipboardCloudSyncReport, finishedTimeMS: Int64,
                 localHistoryInspected: Int? = nil) {
        guard report.enabled, finishedTimeMS > 0,
              report.uploaded >= 0, report.uploaded <= 100,
              report.downloaded >= 0, report.downloaded <= 200,
              report.pending >= 0,
              report.pending <= 1_000_000 else { return nil }
        self.finishedTimeMS = finishedTimeMS
        uploaded = report.uploaded
        downloaded = report.downloaded
        pending = report.pending
        moreComing = report.moreComing
        self.localHistoryInspected = localHistoryInspected
    }

    public var isBacklogCleared: Bool {
        pending == 0 && !moreComing
    }
}
