import Foundation

/// Default is lossless. Coalescing is opt-in and only affects two
/// consecutive, identical plain-text clipboard observations within 10 min.
public enum ClipboardTextDuplicatePolicy: String, Codable, CaseIterable, Sendable {
    case keepAll
    case refreshLatest

    public var title: String {
        switch self {
        case .keepAll: return "Keep every copy"
        case .refreshLatest: return "Refresh newest identical plain-text copy"
        }
    }
}
