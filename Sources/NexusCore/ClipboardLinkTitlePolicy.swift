import Foundation

/// Only accepts a title explicitly supplied by the SAME pasteboard event
/// as a standalone HTTP(S) URL. No webpage requests, HTML parsing, WebKit,
/// outgoing traffic or title guessing from clipboard content.
public enum ClipboardLinkTitlePolicy {
    public static func sanitized(
        _ candidate: String?, copiedText: String
    ) -> String? {
        guard case .webLink = ClipboardTextPreview.classify(copiedText),
              let candidate else { return nil }
        let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160, title.utf8.count <= 512,
              !title.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let source = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != source else { return nil }
        return title
    }
}
