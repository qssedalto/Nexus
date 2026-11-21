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
            "ts", "json", "bash", "sh", "zsh",
            "rust", "rs", "go", "golang", "java", "kotlin", "kt",
            "c", "h", "cpp", "c++", "cc", "cxx", "hpp",
            "csharp", "cs", "ruby", "rb", "php", "sql",
            "r", "rscript", "julia", "jl", "yaml", "yml",
            "toml", "css", "html", "xml", "lua"
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
        case "json", "yaml", "yml", "toml":
            keywords = ["true", "false", "null", "yes", "no"]
        case "bash", "sh", "zsh":
            keywords = [
                "if", "then", "else", "fi", "for", "do", "done",
                "in", "case", "esac", "function", "while", "until", "select"
            ]
        case "rust", "rs":
            keywords = [
                "fn", "let", "mut", "impl", "trait", "struct", "enum", "use",
                "pub", "crate", "mod", "match", "if", "else", "loop",
                "for", "in", "while", "return", "async", "await", "move",
                "where", "type", "const", "static", "Self", "self", "true", "false"
            ]
        case "go", "golang":
            keywords = [
                "package", "import", "func", "type", "struct", "interface",
                "var", "const", "map", "chan", "go", "defer", "select",
                "case", "default", "if", "else", "for", "range", "return",
                "break", "continue", "fallthrough", "nil", "true", "false"
            ]
        case "java":
            keywords = [
                "package", "import", "public", "private", "protected",
                "class", "interface", "enum", "record", "static", "final",
                "void", "new", "this", "super", "return", "if", "else",
                "for", "while", "switch", "case", "try", "catch", "throws",
                "throw", "boolean", "int", "long", "double", "true", "false", "null"
            ]
        case "kotlin", "kt":
            keywords = [
                "package", "import", "fun", "val", "var", "class", "object",
                "interface", "data", "sealed", "when", "is", "in", "as",
                "suspend", "override", "open", "private", "public", "internal",
                "if", "else", "for", "while", "return", "null", "true", "false"
            ]
        case "c", "h", "cpp", "c++", "cc", "cxx", "hpp":
            keywords = [
                "include", "define", "typedef", "struct", "enum", "union",
                "int", "long", "short", "char", "float", "double", "void",
                "const", "static", "extern", "volatile", "return", "if", "else",
                "for", "while", "switch", "case", "break", "continue",
                "class", "namespace", "template", "typename", "auto",
                "public", "private", "protected", "virtual", "constexpr",
                "nullptr", "true", "false", "using", "new", "delete"
            ]
        case "csharp", "cs":
            keywords = [
                "using", "namespace", "class", "struct", "record", "interface",
                "enum", "public", "private", "protected", "internal",
                "static", "void", "var", "int", "string", "bool", "async",
                "await", "return", "if", "else", "for", "foreach",
                "while", "switch", "case", "new", "null", "true", "false"
            ]
        case "ruby", "rb":
            keywords = [
                "def", "class", "module", "end", "if", "elsif", "else",
                "unless", "while", "until", "do", "begin", "rescue", "ensure",
                "return", "yield", "require", "include", "self",
                "nil", "true", "false", "and", "or", "not"
            ]
        case "php":
            keywords = [
                "function", "class", "interface", "trait", "namespace",
                "use", "public", "private", "protected", "static", "new",
                "if", "else", "elseif", "foreach", "while", "for",
                "return", "throw", "try", "catch", "true", "false", "null"
            ]
        case "sql":
            keywords = [
                "select", "from", "where", "join", "inner", "left", "right",
                "outer", "on", "group", "by", "order", "having", "limit",
                "offset", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "alter", "drop", "index",
                "and", "or", "not", "null", "true", "false", "as",
                "distinct", "count", "sum", "max", "min", "case", "when",
                "then", "else", "end", "with", "recursive"
            ]
        case "r", "rscript":
            keywords = [
                "function", "if", "else", "for", "while", "repeat", "break",
                "next", "in", "TRUE", "FALSE", "NULL", "NA", "NaN",
                "Inf", "return", "library", "require"
            ]
        case "julia", "jl":
            keywords = [
                "function", "end", "if", "elseif", "else", "for", "in",
                "while", "begin", "let", "struct", "mutable", "module",
                "using", "import", "export", "where", "return", "break",
                "continue", "true", "false", "nothing", "missing"
            ]
        case "html", "xml":
            keywords = [
                "html", "head", "body", "title", "div", "span", "p",
                "strong", "em", "a", "img", "button", "input",
                "section", "article", "table", "tr", "td", "script", "style"
            ]
        case "css":
            keywords = [
                "color", "background", "display", "position", "flex",
                "grid", "margin", "padding", "width", "height",
                "border", "none", "block", "inline", "relative", "absolute"
            ]
        case "lua":
            keywords = [
                "local", "function", "end", "if", "then", "elseif",
                "else", "for", "in", "while", "do", "repeat", "until",
                "return", "break", "nil", "true", "false", "and", "or", "not"
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
        let hashCommentLanguages: Set<String> = [
            "py", "python", "bash", "sh", "zsh", "ruby", "rb",
            "php", "r", "rscript", "julia", "jl", "yaml", "yml", "toml"
        ]
        let slashCommentLanguages: Set<String> = [
            "swift", "javascript", "js", "typescript", "ts",
            "rust", "rs", "go", "golang", "java", "kotlin", "kt",
            "c", "h", "cpp", "c++", "cc", "cxx", "hpp",
            "csharp", "cs", "php"
        ]
        let blockCommentLanguages: Set<String> = slashCommentLanguages
            .union(["css", "sql"])
        let dashComment = language == "sql" || language == "lua"
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
            if (hashCommentLanguages.contains(language) && c == "#")
                || (slashCommentLanguages.contains(language) && c == "/"
                    && index + 1 < chars.count && chars[index + 1] == "/")
                || (dashComment && c == "-" && index + 1 < chars.count
                    && chars[index + 1] == "-") {
                index += 1
                while index < chars.count && chars[index] != "\n" {
                    index += 1
                }
                emit(.comment, from: start, at: startUTF16, to: index)
            } else if blockCommentLanguages.contains(language) && c == "/"
                        && index + 1 < chars.count && chars[index + 1] == "*" {
                index += 2
                while index < chars.count {
                    if index + 1 < chars.count
                        && chars[index] == "*" && chars[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                emit(.comment, from: start, at: startUTF16, to: index)
            } else if ["html", "xml"].contains(language) && c == "<"
                        && index + 3 < chars.count
                        && chars[index + 1] == "!"
                        && chars[index + 2] == "-"
                        && chars[index + 3] == "-" {
                index += 4
                while index < chars.count {
                    if index + 2 < chars.count && chars[index] == "-"
                        && chars[index + 1] == "-" && chars[index + 2] == ">" {
                        index += 3
                        break
                    }
                    index += 1
                }
                emit(.comment, from: start, at: startUTF16, to: index)
            } else if c == "\"" || (language != "json" && c == "'") {
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" && index + 1 < chars.count {
                        index += 2
                    } else if language == "sql" && c == "'"
                                && chars[index] == "'"
                                && index + 1 < chars.count && chars[index + 1] == "'" {
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
                let word = String(chars[start..<index])
                if keywords.contains(language == "sql" ? word.lowercased() : word) {
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
