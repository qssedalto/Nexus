import XCTest
@testable import SlashgrabCore

final class ClipboardRetentionActivityPolicyTests: XCTestCase {
    func testPausingClipboardCaptureDoesNotDisableExpiry() {
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: true, files: true, text: true, images: true))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 30, maximumHistoryRecords: 0))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 0, maximumHistoryRecords: 500))
    }

    func testNoCaptureConsentCanStillExpireOldRecords() {
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 7, maximumHistoryRecords: 0))
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 0, maximumHistoryRecords: 0))
    }

    func testActiveCaptureAndUnlimitedRetentionStayIndependent() {
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: true, images: false))
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 0, maximumHistoryRecords: 0))
    }
}
