import XCTest
@testable import NexusCore

final class ClipboardPasteSafetyTests: XCTestCase {
    func testMatchingClipboardAndFrontmostAppCanRequestPaste() {
        XCTAssertTrue(ClipboardPasteSafety.canRequestPaste(
            hasAccessibilityPermission: true,
            expectedTargetPID: 4242, currentFrontmostPID: 4242,
            expectedClipboardChangeCount: 10, currentClipboardChangeCount: 10
        ))
    }

    func testInterveningUserCopyOrFocusChangePreventsPaste() {
        XCTAssertFalse(ClipboardPasteSafety.canRequestPaste(
            hasAccessibilityPermission: true,
            expectedTargetPID: 4242, currentFrontmostPID: 4242,
            expectedClipboardChangeCount: 10, currentClipboardChangeCount: 11
        ))
        XCTAssertFalse(ClipboardPasteSafety.canRequestPaste(
            hasAccessibilityPermission: true,
            expectedTargetPID: 4242, currentFrontmostPID: 999,
            expectedClipboardChangeCount: 10, currentClipboardChangeCount: 10
        ))
        XCTAssertFalse(ClipboardPasteSafety.canRequestPaste(
            hasAccessibilityPermission: true,
            expectedTargetPID: 4242, currentFrontmostPID: nil,
            expectedClipboardChangeCount: 10, currentClipboardChangeCount: 10
        ))
        XCTAssertFalse(ClipboardPasteSafety.canRequestPaste(
            hasAccessibilityPermission: false,
            expectedTargetPID: 4242, currentFrontmostPID: 4242,
            expectedClipboardChangeCount: 10, currentClipboardChangeCount: 10
        ))
    }
}
