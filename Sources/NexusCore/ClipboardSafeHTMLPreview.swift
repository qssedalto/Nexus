import Foundation

/// A deliberately small, offline and fail-closed HTML typography parser.
/// It never initializes WebKit, resolves URLs, loads resources or persists
/// original HTML. Unsupported tags/attributes reject the entire preview;
/// the caller should always fall back to the existing plain-text copy.
public enum ClipboardSafeHTMLPreview {
    private static let maximumInputBytes = 128 * 1024
    private static let maximumTextBytes = 64 * 1024
    private static let maximumElements = 2_000
    private static let maximumNesting = 32

    public static func parse(_ source: String) -> ClipboardRichTextPreview? {
        guard !source.isEmpty, source.utf8.count <= maximumInputBytes else {
            return nil
        }
        let chars = Array(source)
        var index = 0
        var output = ""
        var outputUTF16 = 0
        var outputBytes = 0
        var tags: [String] = []
        var boldDepth = 0
        var italicDepth = 0
        var underlineDepth = 0
        var seenTag = false
        var elementCount = 0
        var runs: [ClipboardRichTextRun] = []

        func append(_ character: Character) -> Bool {
            let value = String(character)
            let bytes = value.utf8.count
            guard bytes <= maximumTextBytes - outputBytes else { return false }
            let length = value.utf16.count
            let location = outputUTF16
            output.append(character)
            outputBytes += bytes
            outputUTF16 += length
            let bold = boldDepth > 0
            let italic = italicDepth > 0
            let underline = underlineDepth > 0
            guard bold || italic || underline else { return true }
            if let last = runs.last,
               last.locationUTF16 + last.lengthUTF16 == location,
               last.bold == bold, last.italic == italic,
               last.underline == underline {
                runs[runs.count - 1] = ClipboardRichTextRun(
                    locationUTF16: last.locationUTF16,
                    lengthUTF16: last.lengthUTF16 + length,
                    bold: bold, italic: italic, underline: underline
                )
            } else {
                guard runs.count < 512 else { return false }
                runs.append(ClipboardRichTextRun(
                    locationUTF16: location, lengthUTF16: length,
                    bold: bold, italic: italic, underline: underline
                ))
            }
            return true
        }

        while index < chars.count {
            let ch = chars[index]
            if ch == "<" {
                var end = index + 1
                while end < chars.count, chars[end] != ">", end - index <= 64 {
                    end += 1
                }
                guard end < chars.count, chars[end] == ">",
                      end - index <= 64 else { return nil }
                let token = String(chars[(index + 1)..<end]).lowercased()
                // No attributes (including URL, style, event handlers),
                // doctypes, comments, scripts, or arbitrary HTML are allowed.
                let isClosing = token.first == "/"
                var name = isClosing ? String(token.dropFirst()) : token
                let isSelfClosing = name.hasSuffix("/")
                if isSelfClosing { name.removeLast() }
                let supported = [
                    "b", "strong", "i", "em", "u", "span", "p", "div", "br",
                    "h1", "h2", "h3", "h4", "h5", "h6",
                    "ul", "ol", "li", "blockquote", "pre", "code",
                    "section", "article"
                ]
                guard supported.contains(name),
                      !name.contains(where: { $0.isWhitespace }),
                      !(isClosing && isSelfClosing) else { return nil }
                elementCount += 1
                guard elementCount <= maximumElements else { return nil }
                seenTag = true
                if name == "br" {
                    guard !isClosing, append("\n") else { return nil }
                } else if isClosing {
                    guard tags.last == name else { return nil }
                    tags.removeLast()
                    switch name {
                    case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6":
                        boldDepth -= 1
                    case "i", "em": italicDepth -= 1
                    case "u": underlineDepth -= 1
                    default: break
                    }
                } else {
                    guard !isSelfClosing, tags.count < maximumNesting else {
                        return nil
                    }
                    // List items must belong to a list; unlike a WebKit
                    // renderer, this parser intentionally accepts no CSS,
                    // image tags, HTML attributes, links or external assets.
                    if name == "li", !tags.contains("ul") && !tags.contains("ol") {
                        return nil
                    }
                    let isBlock = [
                        "p", "div", "h1", "h2", "h3", "h4", "h5",
                        "h6", "li", "blockquote", "pre", "section", "article"
                    ].contains(name)
                    if isBlock && !output.isEmpty && !output.hasSuffix("\n") {
                        guard append("\n") else { return nil }
                    }
                    tags.append(name)
                    switch name {
                    case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6":
                        boldDepth += 1
                    case "i", "em": italicDepth += 1
                    case "u": underlineDepth += 1
                    default: break
                    }
                }
                index = end + 1
            } else if ch == "&" {
                var end = index + 1
                while end < chars.count, chars[end] != ";", end - index <= 15 {
                    end += 1
                }
                guard end < chars.count, chars[end] == ";",
                      end - index <= 15 else { return nil }
                let entity = String(chars[(index + 1)..<end])
                guard let decoded = decodeEntity(entity) else { return nil }
                for scalar in decoded {
                    guard append(Character(String(scalar))) else { return nil }
                }
                index = end + 1
            } else {
                guard append(ch) else { return nil }
                index += 1
            }
        }

        guard seenTag, tags.isEmpty else { return nil }
        return ClipboardRichTextPreview(text: output, runs: runs)
    }

    private static func decodeEntity(_ entity: String) -> [UnicodeScalar]? {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
            "apos": "'", "nbsp": "\u{00A0}"
        ]
        if let value = named[entity] { return Array(value.unicodeScalars) }
        guard entity.hasPrefix("#") else { return nil }
        let number = String(entity.dropFirst())
        let radix: Int
        let digits: String
        if number.hasPrefix("x") || number.hasPrefix("X") {
            radix = 16
            digits = String(number.dropFirst())
        } else {
            radix = 10
            digits = number
        }
        guard !digits.isEmpty, digits.count <= 8,
              let point = UInt32(digits, radix: radix),
              let scalar = UnicodeScalar(point),
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar) else {
            return nil
        }
        return [scalar]
    }
}
