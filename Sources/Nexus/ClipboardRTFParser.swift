import AppKit
import Foundation
import SlashgrabCore

/// Parses the RTF pasteboard representation into a tiny, safe subset of
/// typography. Never stores raw rich content, links, fonts, attachments,
/// HTML, remote images or active embedded resources.
enum ClipboardRTFParser {
    static func sanitizedPreview(from data: Data) -> ClipboardRichTextPreview? {
        guard !data.isEmpty, data.count <= 128 * 1024 else { return nil }
        guard let document = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        guard document.length > 0, document.length <= 64 * 1024,
              document.string.utf8.count <= 64 * 1024 else { return nil }
        var runs: [ClipboardRichTextRun] = []
        var disallowed = false
        document.enumerateAttributes(
            in: NSRange(location: 0, length: document.length),
            options: []
        ) { attributes, range, stop in
            if attributes[.attachment] != nil {
                disallowed = true
                stop.pointee = true
                return
            }
            let traits = (attributes[.font] as? NSFont)?
                .fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            let underlined = (attributes[.underlineStyle] as? NSNumber)?
                .intValue ?? 0 != 0
            if bold || italic || underlined {
                runs.append(ClipboardRichTextRun(
                    locationUTF16: range.location,
                    lengthUTF16: range.length,
                    bold: bold, italic: italic, underline: underlined
                ))
            }
            if runs.count > 512 {
                disallowed = true
                stop.pointee = true
            }
        }
        guard !disallowed else { return nil }
        return ClipboardRichTextPreview(text: document.string, runs: runs)
    }
}
