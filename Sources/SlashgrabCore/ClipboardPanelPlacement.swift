import CoreGraphics
import Foundation

/// Calculates a bottom shelf frame in global screen points, including
/// external monitors with negative origins and displays with nonstandard
/// scaling. Caller chooses the mouse-containing NSScreen before invoking.
public enum ClipboardPanelPlacement {
    public static func frame(
        inside visibleFrame: CGRect,
        requestedSize: CGSize,
        sideInset: CGFloat = 12,
        bottomInset: CGFloat = 20
    ) -> CGRect {
        let inset = max(0, sideInset)
        let bottom = max(0, bottomInset)
        let availableWidth = max(1, visibleFrame.width - 2 * inset)
        let availableHeight = max(1, visibleFrame.height - bottom - 10)
        let width = min(max(1, requestedSize.width), availableWidth)
        let height = min(max(1, requestedSize.height), availableHeight)
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.minY + min(bottom, max(0, visibleFrame.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
