import AppKit
import NexusCore
import SwiftUI

/// Lazy presentation of pre-sanitized formatting metadata. Plain clipboard
/// text remains available as the fallback and the original RTF is not read.
struct ClipboardRichTextExcerpt: View {
    let operationID: String
    let fallback: String
    let monospaced: Bool

    @State private var rendered: AttributedString?

    var body: some View {
        Group {
            if let rendered {
                Text(rendered)
                    .font(.caption)
            } else {
                Text(fallback)
                    .font(monospaced
                          ? .system(size: 11, design: .monospaced)
                          : .caption)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .task(id: operationID) {
            rendered = nil
            let store = OperationStore.shared()
            let preview = await Task.detached(priority: .utility) {
                try? store?.richTextPreview(operationID: operationID)
            }.value
            guard !Task.isCancelled, let preview else { return }
            rendered = Self.makeAttributed(preview)
        }
    }

    private static func makeAttributed(
        _ preview: ClipboardRichTextPreview
    ) -> AttributedString {
        let attributed = NSMutableAttributedString(string: preview.text)
        for run in preview.runs {
            let range = NSRange(
                location: run.locationUTF16, length: run.lengthUTF16
            )
            var font = NSFont.systemFont(ofSize: 11)
            if run.bold {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if run.italic {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            attributed.addAttribute(.font, value: font, range: range)
            if run.underline {
                attributed.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue, range: range
                )
            }
        }
        return AttributedString(attributed)
    }
}
