import Foundation

/// A verified paste target and unchanged clipboard revision are prerequisites
/// for a synthetic paste request. This does not prove the target accepted it.
public enum ClipboardPasteSafety {
    public static func canRequestPaste(
        hasAccessibilityPermission: Bool,
        expectedTargetPID: Int32,
        currentFrontmostPID: Int32?,
        expectedClipboardChangeCount: Int,
        currentClipboardChangeCount: Int
    ) -> Bool {
        hasAccessibilityPermission
            && expectedTargetPID > 0
            && currentFrontmostPID == expectedTargetPID
            && expectedClipboardChangeCount == currentClipboardChangeCount
    }
}
