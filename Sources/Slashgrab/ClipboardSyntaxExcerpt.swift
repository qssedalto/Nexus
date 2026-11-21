import AppKit
import SlashgrabCore
import SwiftUI

/// Read-only syntax colors, generated from an explicit Markdown code fence.
/// The original clipboard bytes remain unmodified for Copy Again and Paste.
struct ClipboardSyntaxExcerpt: View {
    let source: String
    @State private var rendered: AttributedString?

    var body: some View {
        Group {
            if let rendered {
                Text(rendered)
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Text(source)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .task(id: source) {
            rendered = nil
            let input = source
            let preview = await Task.detached(priority: .utility) {
                ClipboardCodePreview.parse(input)
            }.value
            guard !Task.isCancelled, let preview else { return }
            let document = NSMutableAttributedString(string: preview.code)
            let fullRange = NSRange(location: 0, length: preview.code.utf16.count)
            document.addAttributes([
                .font: NSFont.monospacedSystemFont(
                    ofSize: 11, weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: fullRange)
            for token in preview.tokens {
                let color: NSColor
                switch token.kind {
                case .keyword: color = .systemPurple
                case .string: color = .systemGreen
                case .number: color = .systemOrange
                case .comment: color = .tertiaryLabelColor
                }
                document.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: token.locationUTF16,
                                   length: token.lengthUTF16)
                )
            }
            rendered = AttributedString(document)
        }
    }
}
