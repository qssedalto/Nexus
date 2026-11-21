import Foundation

/// The macOS pasteboard does not certify which application wrote its data.
/// Preserve that distinction when displaying best-effort foreground metadata.
public enum ClipboardSourceAttribution: Equatable, Sendable {
    case unknown
    case observedForeground(bundleID: String)
    case reported(bundleID: String)

    public static func classify(_ operation: RecordedOperation) -> ClipboardSourceAttribution {
        guard let id = operation.sourceApplication, !id.isEmpty else {
            return .unknown
        }
        if operation.detectionMethod.contains("frontmost_observed") {
            return .observedForeground(bundleID: id)
        }
        return .reported(bundleID: id)
    }
}
