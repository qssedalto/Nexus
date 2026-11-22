import XCTest
@testable import NexusCore

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

    func testHistoryMasterSwitchStopsObservationButNotConfiguredExpiry() {
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: true, text: true, images: true,
            historyEnabled: false))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: true, text: false, images: false,
            historyEnabled: true))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 30, maximumHistoryRecords: 100))
    }

    func testActiveCaptureAndUnlimitedRetentionStayIndependent() {
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: true, images: false))
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldRunCleanup(
            retentionDays: 0, maximumHistoryRecords: 0))
    }

    func testExplicitFolderMirroringKeepsObservationRunningWithoutHistoryFormats() {
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false,
            mirrorEnabled: false, mirrorFiles: true, mirrorText: true))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false,
            mirrorEnabled: true, mirrorFiles: true))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false,
            mirrorEnabled: true, mirrorImages: true))
        XCTAssertTrue(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false,
            mirrorEnabled: true, mirrorText: true))
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: true, files: false, text: false, images: false,
            mirrorEnabled: true, mirrorText: true))
        XCTAssertFalse(ClipboardRetentionActivityPolicy.shouldObserve(
            paused: false, files: false, text: false, images: false,
            historyEnabled: false, mirrorEnabled: true, mirrorFiles: true))
    }

}
