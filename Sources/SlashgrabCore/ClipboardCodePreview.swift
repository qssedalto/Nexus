import Foundation

public enum ClipboardSyntaxClass: String, Sendable, Equatable {
    case keyword, string, number, comment
}

public struct ClipboardSyntaxToken: Sendable, Equatable {
    public let locationUTF16: Int
    public let lengthUTF16: Int
    public let kind: ClipboardSyntaxClass

    public init(locationUTF16: Int, lengthUTF16: Int, kind: ClipboardSyntaxClass) {
        self.locationUTF16 = locationUTF16
        self.lengthUTF16 = lengthUTF16
        self.kind = kind
    }
}

/// Offline, bounded and presentation-only lexer. Nexus only highlights
/// explicitly fenced source code; it never guesses from freeform clipboard
/// content, evaluates code, runs commands, or fetches language definitions.
public struct ClipboardCodePreview: Sendable, Equatable {
    public let language: String
    public let code: String
    public let tokens: [ClipboardSyntaxToken]

    public static func parse(_ text: String) -> ClipboardCodePreview? {
        guard text.utf8.count <= 18 * 1024,
              case .fencedCode(let rawLanguage) = ClipboardTextPreview.classify(text),
              let language = rawLanguage?.lowercased() else { return nil }

        let supported: Set<String> = [
            "swift", "python", "py", "javascript", "js", "typescript",
            "ts", "json", "bash", "sh"
        ]
        guard supported.contains(language) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 3 else { return nil }
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
        guard !body.isEmpty, body.utf8.count <= 16 * 1024 else { return nil }
        return ClipboardCodePreview(
            language: language, code: body,
            tokens: tokenize(body, language: language)
        )
    }

    private static func tokenize(
        _ code: String, language: String
    ) -> [ClipboardSyntaxToken] {
        let keywords: Set<String>
        switch language {
        case "swift":
            keywords = [
                "let", "var", "func", "class", "struct", "enum",
                "protocol", "extension", "import", "guard", "if", "else",
                "return", "throw", "throws", "try", "await", "async",
                "for", "in", "while", "switch", "case", "default",
                "nil", "true", "false", "public", "private", "static"
            ]
        case "python", "py":
            keywords = [
                "def", "class", "return", "if", "elif", "else",
                "for", "in", "while", "import", "from", "as", "with",
                "try", "except", "finally", "raise", "async", "await",
                "lambda", "yield", "True", "False", "None", "and",
                "or", "not", "is", "pass"
            ]
        case "json":
            keywords = ["true", "false", "null"]
        case "bash", "sh":
            keywords = [
                "if", "then", "else", "fi", "for", "do", "done",
                "in", "case", "esac", "function", "while"
            ]
        default:
            keywords = [
                "let", "const", "var", "function", "return", "if",
                "else", "class", "new", "import", "export",
                "default", "async", "await", "try", "catch",
                "throw", "for", "while", "switch", "case",
                "true", "false", "null", "undefined", "interface",
                "type", "enum", "extends", "implements"
            ]
        }
        let chars = Array(code)
        let isHashComment = ["py", "python", "bash", "sh"].contains(language)
        let allowsSlashComments = !isHashComment && language != "json"
        var offset = 0
        var index = 0
        var results: [ClipboardSyntaxToken] = []
        func isIdentifierHead(_ c: Character) -> Bool {
            c.isLetter || c == "_"
        }
        func isIdentifierPart(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }
        func length(_ range: Range<Int>) -> Int {
            String(chars[range]).utf16.count
        }
        func emit(_ kind: ClipboardSyntaxClass, from start: Int,
                  at utf16Location: Int, to end: Int) {
            guard results.count < 256 else { return }
            results.append(ClipboardSyntaxToken(
                locationUTF16: utf16Location,
                lengthUTF16: length(start..<end), kind: kind
            ))
        }

        while index < chars.count && results.count < 256 {
            let start = index
            let startUTF16 = offset
            let c = chars[index]
            if (isHashComment && c == "#")
                || (allowsSlashComments && c == "/"
                    && index + 1 < chars.count && chars[index + 1] == "/") {
                index += 1
                while index < chars.count && chars[index] != "\n" {
                    index += 1
                }
                emit(.comment, from: start, at: startUTF16, to: index)
            } else if c == "\"" || (language != "json" && c == "'") {
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" && index + 1 < chars.count {
                        index += 2
                    } else if chars[index] == c {
                        index += 1
                        break
                    } else if chars[index] == "\n" {
                        break
                    } else {
                        index += 1
                    }
                }
                emit(.string, from: start, at: startUTF16, to: index)
            } else if c.isNumber {
                index += 1
                while index < chars.count
                    && (chars[index].isNumber || chars[index] == ".") {
                    index += 1
                }
                emit(.number, from: start, at: startUTF16, to: index)
            } else if isIdentifierHead(c) {
                index += 1
                while index < chars.count && isIdentifierPart(chars[index]) {
                    index += 1
                }
                if keywords.contains(String(chars[start..<index])) {
                    emit(.keyword, from: start, at: startUTF16, to: index)
                }
            } else {
                index += 1
            }
            offset += length(start..<index)
        }
        return results
    }
}
