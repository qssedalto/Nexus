import Foundation

/// Limits explicit URL-title discovery to a normal public HTTPS website.
/// There are no automatic requests: callers must also obtain two UI consents.
/// This conservative policy rejects private link tokens, local hosts and IPs.
public enum ClipboardRemoteWebTitlePolicy {
    public static let maximumHTMLBytes = 128 * 1024

    public static func eligibleURL(_ copiedText: String) -> URL? {
        guard copiedText.utf8.count <= 2_048,
              case .webLink = ClipboardTextPreview.classify(copiedText),
              let parts = URLComponents(string: copiedText
                .trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-"
              ).contains($0) }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63
                  && $0.first != "-" && $0.last != "-"
              }),
              let suffix = labels.last, suffix.count >= 2,
              suffix.allSatisfy({ $0.isLetter }),
              !["local", "localhost", "lan", "internal", "test",
                 "invalid", "example", "onion", "home", "arpa"].contains(String(suffix)),
              let url = parts.url else { return nil }
        return url
    }

    /// Parses a bounded ordinary HTML title only. No script or browser DOM,
    /// resource resolution, HTML rendering, JS evaluation or CSS is involved.
    public static func title(fromHTML data: Data, copiedText: String) -> String? {
        guard data.count <= maximumHTMLBytes,
              let html = String(data: data, encoding: .utf8),
              let open = html.range(of: "<title>", options: .caseInsensitive),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: open.upperBound..<html.endIndex) else {
            return nil
        }
        let raw = String(html[open.upperBound..<close.lowerBound])
        guard raw.utf8.count <= 768,
              !raw.contains("<"), !raw.contains(">") else { return nil }
        let substitutions = [
            ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")
        ]
        // Reject malformed/unknown entities rather than mistaking a
        // partially decoded document or script for an ordinary page title.
        let allowedEntities: Set<String> = Set(
            substitutions.map { $0.0 }
        )
        var cursor = raw.startIndex
        while let ampersand = raw[cursor...].firstIndex(of: "&") {
            guard let end = raw[ampersand...].firstIndex(of: ";"),
                  raw.distance(from: ampersand, to: end) <= 9,
                  allowedEntities.contains(
                    String(raw[ampersand...end]).lowercased()
                  ) else { return nil }
            cursor = raw.index(after: end)
        }
        var title = raw
        for (escaped, literal) in substitutions {
            title = title.replacingOccurrences(
                of: escaped, with: literal, options: .caseInsensitive
            )
        }
        guard !title.contains("<"), !title.contains(">") else { return nil }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardLinkTitlePolicy.sanitized(
            title, copiedText: copiedText
        )
    }
}
