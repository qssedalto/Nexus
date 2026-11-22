import AppKit
import NexusCore

/// Recreates a saved clipboard entry without treating its preview as content.
@MainActor
enum ClipboardRecordRestorer {
    static func restore(_ operation: RecordedOperation) -> String? {
        let pasteboard = NSPasteboard.general
        if operation.type == "image_copy" {
            guard let image = try? OperationStore.shared()?.imageContent(operationID: operation.id) else {
                return localized("Original clipboard image unavailable")
            }
            pasteboard.clearContents()
            guard pasteboard.setData(image.data, forType: .init(image.pasteboardType)) else {
                return localized("Clipboard write failed")
            }
        } else if let text = operation.clipboardText, !text.isEmpty {
            pasteboard.clearContents()
            if let rich = try? OperationStore.shared()?.richTextPreview(operationID: operation.id),
               rich.text == text {
                let attributed = NSMutableAttributedString(string: text)
                for run in rich.runs {
                    let range = NSRange(location: run.locationUTF16, length: run.lengthUTF16)
                    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize,
                                                 weight: run.bold ? .bold : .regular)
                    if run.italic {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    attributed.addAttribute(.font, value: font, range: range)
                    if run.underline {
                        attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                                range: range)
                    }
                }
                guard pasteboard.writeObjects([attributed]) else {
                    return localized("Clipboard write failed")
                }
            } else if !pasteboard.setString(text, forType: .string) {
                return localized("Clipboard write failed")
            }
        } else {
            let urls = operation.items.compactMap { item -> NSURL? in
                guard let path = item.source, path.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: path) else { return nil }
                return NSURL(fileURLWithPath: path)
            }
            guard !urls.isEmpty, urls.count == operation.items.count else {
                return localized("Source file unavailable")
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(urls) else { return localized("Clipboard write failed") }
        }
        ClipboardMonitor.shared.ignoreCurrentChange()
        return nil
    }
}
