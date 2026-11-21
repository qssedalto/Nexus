import Foundation

/// Stable, allowlisted color markers. No arbitrary colors or executable
/// appearance data are persisted in the clipboard history database.
public enum ClipboardCardAccent: String, Codable, CaseIterable, Sendable {
    case automatic, red, orange, yellow, green, blue, purple, gray

    public var title: String {
        switch self {
        case .automatic: return "Automatic color"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }
}
