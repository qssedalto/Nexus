import Foundation

/// Sanitized presentation metadata for copied RTF: text plus a small set of
/// safe typographic flags. No raw HTML/RTF, attachments, hyperlinks, remote
/// images, fonts, colors or active content are persisted in this data model.
public struct ClipboardRichTextRun: Codable, Sendable, Equatable {
    public let locationUTF16: Int
    public let lengthUTF16: Int
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool

    public init(locationUTF16: Int, lengthUTF16: Int,
                bold: Bool, italic: Bool, underline: Bool) {
        self.locationUTF16 = locationUTF16
        self.lengthUTF16 = lengthUTF16
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }
}

public struct ClipboardRichTextPreview: Codable, Sendable, Equatable {
    public let text: String
    public let runs: [ClipboardRichTextRun]

    public init?(text: String, runs: [ClipboardRichTextRun]) {
        guard !text.isEmpty, text.utf8.count <= 64 * 1024,
              !runs.isEmpty, runs.count <= 512 else { return nil }
        let length = text.utf16.count
        for run in runs {
            guard run.locationUTF16 >= 0, run.lengthUTF16 > 0,
                  run.locationUTF16 <= length,
                  run.lengthUTF16 <= length - run.locationUTF16,
                  run.bold || run.italic || run.underline else { return nil }
        }
        self.text = text
        self.runs = runs
    }
}
