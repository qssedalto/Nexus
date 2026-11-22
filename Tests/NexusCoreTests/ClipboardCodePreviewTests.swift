import XCTest
@testable import NexusCore

final class ClipboardCodePreviewTests: XCTestCase {
    private func fenced(_ lang: String, _ body: String) -> String {
        let marker = String(repeating: "\u{0060}", count: 3)
        return marker + lang + "\n" + body + "\n" + marker
    }

    func testSwiftFenceHighlightsKeywordsStringsAndNumbersWithUTF16() throws {
        let p = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("swift", "let greeting = \"你好😀\"\nlet count = 42")
        ))
        XCTAssertEqual(p.language, "swift")
        XCTAssertEqual(p.code, "let greeting = \"你好😀\"\nlet count = 42")
        XCTAssertTrue(p.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(p.tokens.contains { $0.kind == .number })
        XCTAssertTrue(p.tokens.contains {
            $0.kind == .string && $0.lengthUTF16 == "\"你好😀\"".utf16.count
        })
        for token in p.tokens {
            XCTAssertGreaterThan(token.lengthUTF16, 0)
            XCTAssertLessThanOrEqual(token.locationUTF16 + token.lengthUTF16,
                                     p.code.utf16.count)
        }
    }

    func testPythonCommentShellQuoteAndJSONBoolean() throws {
        let python = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("python", "def hello(): # 注释\n  return 3")
        ))
        XCTAssertTrue(python.tokens.contains { $0.kind == .comment })
        XCTAssertTrue(python.tokens.contains { $0.kind == .keyword })
        let shell = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("bash", "if true; then\n echo 'hi'\nfi")
        ))
        XCTAssertTrue(shell.tokens.contains { $0.kind == .string })
        let json = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("json", "{\"ok\":true,\"n\":12,\"missing\":null}")
        ))
        XCTAssertTrue(json.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(json.tokens.contains { $0.kind == .number })
        XCTAssertFalse(json.tokens.contains { $0.kind == .comment })
    }

    func testUnknownUnfencedAndOversizedCodeIsNotGuessed() {
        XCTAssertNil(ClipboardCodePreview.parse("let x = 10"))
        XCTAssertNil(ClipboardCodePreview.parse(fenced("unknownlanguage", "print(1)")))
        XCTAssertNil(ClipboardCodePreview.parse(
            fenced("swift", String(repeating: "x", count: 18 * 1024))
        ))
    }

    func testSupportedNonSwiftLanguagesStayOfflineAndBounded() throws {
        let examples: [(String, String)] = [
            ("rust", "fn main() { let x = 42; // comment\n}"),
            ("go", "package main\nfunc main() { // note\n}"),
            ("java", "public class Main { int x = 42; }"),
            ("kotlin", "fun main() { val x = 3 }"),
            ("cpp", "int main() { /* block */ return 0; }"),
            ("csharp", "public class Hello { string x = \"abc\"; }"),
            ("ruby", "def hi # comment\nend"),
            ("php", "function hi() { // comment\nreturn true; }"),
            ("sql", "SELECT name FROM users WHERE id = 42 -- note"),
            ("r", "function(x) { # comment\nreturn(x) }"),
            ("julia", "function hi(x) # note\nreturn x\nend"),
            ("yaml", "enabled: true # 配置"),
            ("toml", "enabled = true # comment"),
            ("css", "body { color: #fff; /* style */ }"),
            ("html", "<!-- comment --><div>你好</div>"),
            ("lua", "local x = 1 -- note"),
            ("zsh", "if true; then # comment\necho ok\nfi")
        ]
        for (language, body) in examples {
            let preview = try XCTUnwrap(
                ClipboardCodePreview.parse(fenced(language, body)), language
            )
            XCTAssertFalse(preview.tokens.isEmpty, language)
            XCTAssertEqual(preview.language, language)
            XCTAssertLessThanOrEqual(preview.tokens.count, 256, language)
            for token in preview.tokens {
                XCTAssertGreaterThan(token.lengthUTF16, 0, language)
                XCTAssertLessThanOrEqual(
                    token.locationUTF16 + token.lengthUTF16,
                    preview.code.utf16.count, language
                )
            }
        }
    }

    func testSQLCaseInsensitiveKeywordsAndEscapedString() throws {
        let code = "SELECT 'it''s okay' FROM table_name -- 注释😀"
        let p = try XCTUnwrap(ClipboardCodePreview.parse(fenced("sql", code)))
        XCTAssertEqual(p.tokens.filter { $0.kind == .keyword }.count, 2)
        XCTAssertEqual(p.tokens.filter { $0.kind == .string }.count, 1)
        XCTAssertTrue(p.tokens.contains { $0.kind == .comment })
        for token in p.tokens {
            XCTAssertLessThanOrEqual(
                token.locationUTF16 + token.lengthUTF16,
                p.code.utf16.count
            )
        }
    }

    func testMalformedBlockCommentRemainsInBounds() throws {
        let p = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("rust", "fn f() { /* unclosed😀")
        ))
        XCTAssertTrue(p.tokens.contains { $0.kind == .comment })
        XCTAssertLessThanOrEqual(p.tokens.count, 256)
    }

    func testTokenCountIsBoundedForLargeSource() throws {
        let p = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("swift", String(repeating: "let x = 1\n", count: 300))
        ))
        XCTAssertLessThanOrEqual(p.tokens.count, 256)
    }
}
