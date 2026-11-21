import XCTest
@testable import SlashgrabCore

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

    func testTokenCountIsBoundedForLargeSource() throws {
        let p = try XCTUnwrap(ClipboardCodePreview.parse(
            fenced("swift", String(repeating: "let x = 1\n", count: 300))
        ))
        XCTAssertLessThanOrEqual(p.tokens.count, 256)
    }
}
