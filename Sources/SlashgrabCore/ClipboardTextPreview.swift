import Foundation

/// A presentation-only classifier for text already saved with the user's
/// permission. Never fetch URLs or reinterpret the original pasteboard data.
public enum ClipboardTextPreview: Sendable, Equatable {
    case plain
    case webLink(host: String)
    case fencedCode(language: String?)

    public static func classify(_ original: String) -> ClipboardTextPreview {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .plain }

        // Only standalone HTTP(S) URLs are treated as links. Credentials,
        // multiple lines, script schemes, and ambiguous plain text stay text.
        if text.utf8.count <= 2_048,
           !text.contains(where: { $0.isWhitespace }),
           let parts = URLComponents(string: text),
           let scheme = parts.scheme?.lowercased(),
           scheme == "https" || scheme == "http",
           let host = parts.host, !host.isEmpty,
           parts.user == nil, parts.password == nil,
           parts.port.map({ $0 > 0 && $0 <= 65_535 }) ?? true {
            return .webLink(host: host)
        }

        // Explicit Markdown fences are unambiguous; never guess a code
        // language from ordinary typing, URLs or clipboard contents.
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 3,
           let first = lines.first, first.hasPrefix("```"),
           lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```",
           lines.dropFirst().dropLast().contains(where: { !$0.isEmpty }) {
            let raw = String(first.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "+#._-")
            )
            let language: String? = raw.isEmpty || raw.count > 24 ||
                !raw.unicodeScalars.allSatisfy({ allowed.contains($0) })
                ? nil : raw
            return .fencedCode(language: language)
        }
        return .plain
    }
}
