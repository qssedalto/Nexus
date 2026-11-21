import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudRunSummaryTests: XCTestCase {
    func testStatusPersistsWithoutClipboardsOrTokens() throws {
        let report = ClipboardCloudSyncReport(
            enabled: true, uploaded: 4, downloaded: 7,
            pending: 2, moreComing: true
        )
        let result = try XCTUnwrap(ClipboardCloudRunSummary(
            report: report, finishedTimeMS: 1_800_000_000_000
        ))
        XCTAssertFalse(result.isBacklogCleared)
        let payload = try JSONEncoder().encode(result)
        XCTAssertEqual(
            try JSONDecoder().decode(ClipboardCloudRunSummary.self, from: payload),
            result
        )
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("clipboardText"))
        XCTAssertFalse(text.contains("path"))
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("deviceID"))
    }

    func testDisabledOrOutOfRangeReportsNeverBecomeSuccessfulStatus() {
        XCTAssertNil(ClipboardCloudRunSummary(
            report: .disabled, finishedTimeMS: 1
        ))
        XCTAssertNil(ClipboardCloudRunSummary(
            report: ClipboardCloudSyncReport(
                enabled: true, uploaded: 0, downloaded: 0,
                pending: 0, moreComing: false
            ), finishedTimeMS: 0
        ))
        XCTAssertNil(ClipboardCloudRunSummary(
            report: ClipboardCloudSyncReport(
                enabled: true, uploaded: 101, downloaded: 0,
                pending: 0, moreComing: false
            ), finishedTimeMS: 123
        ))
        let cleared = ClipboardCloudRunSummary(
            report: ClipboardCloudSyncReport(
                enabled: true, uploaded: 0, downloaded: 0,
                pending: 0, moreComing: false
            ), finishedTimeMS: 10
        )
        XCTAssertEqual(cleared?.isBacklogCleared, true)
    }
}
