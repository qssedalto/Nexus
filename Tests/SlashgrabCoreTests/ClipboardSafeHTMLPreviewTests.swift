import XCTest
@testable import SlashgrabCore

final class ClipboardSafeHTMLPreviewTests: XCTestCase {
    func testLocalHTMLBoldItalicUnderlinePreservesUnicodeAndUTF16Ranges() throws {
        let preview = try XCTUnwrap(
            ClipboardSafeHTMLPreview.parse(
                "<p>你好 <strong>世界😀</strong> <em>Apple</em> <u>统计</u></p>"
            )
        )
        XCTAssertEqual(preview.text, "你好 世界😀 Apple 统计")
        XCTAssertTrue(preview.runs.contains {
            $0.bold && $0.locationUTF16 == 3 && $0.lengthUTF16 == 4
        })
        XCTAssertTrue(preview.runs.contains {
            $0.italic && $0.lengthUTF16 == 5
        })
        XCTAssertTrue(preview.runs.contains {
            $0.underline && $0.lengthUTF16 == 2
        })
    }

    func testNestedTypographyPreservesCombinedStylesAndPlainGaps() throws {
        let preview = try XCTUnwrap(
            ClipboardSafeHTMLPreview.parse("<b>A<i>BC</i>D</b> and text")
        )
        XCTAssertEqual(preview.text, "ABCD and text")
        XCTAssertEqual(preview.runs.map(\.lengthUTF16), [1, 2, 1])
        XCTAssertEqual(preview.runs[1].bold, true)
        XCTAssertEqual(preview.runs[1].italic, true)
        XCTAssertFalse(preview.runs[2].italic)
    }

    func testDecodesOnlyBoundedEntitiesWithoutFetchingAnything() throws {
        let preview = try XCTUnwrap(
            ClipboardSafeHTMLPreview.parse("<b>1 &lt; 2 &amp;&amp; 😀 &#x4E2D;&#25991;</b>")
        )
        XCTAssertEqual(preview.text, "1 < 2 && 😀 中文")
        XCTAssertEqual(preview.runs.first?.lengthUTF16, preview.text.utf16.count)
    }

    func testRejectsScriptsURLsImagesAndAnyHTMLAttributes() {
        let dangerous = [
            "<script>alert('x')</script>",
            "<img src='https://example.com/pixel'>",
            "<a href='https://example.com'>Link</a>",
            "<span style='color:red'>Secret</span>",
            "<b onclick='alert(1)'>Bad</b>",
            "<style>@import url(https://example.com)</style>",
            "<!-- comments -->",
            "<!DOCTYPE html><b>hello</b>",
            "<iframe src='about:blank'></iframe>"
        ]
        for html in dangerous {
            XCTAssertNil(ClipboardSafeHTMLPreview.parse(html), html)
        }
    }

    func testMalformedTagsUnknownEntitiesAndUnclosedFormattingFallBack() {
        let invalid = [
            "<b>unclosed",
            "<b><i>x</b></i>",
            "<u>unknown &fake;</u>",
            "<b>bad &#0;</b>",
            "<b>bad &#xD800;</b>",
            "<b>A < B</b>",
            "<p class=test>hello</p>",
            "<b/>hello"
        ]
        for html in invalid {
            XCTAssertNil(ClipboardSafeHTMLPreview.parse(html), html)
        }
        XCTAssertNil(ClipboardSafeHTMLPreview.parse("<p>plain only</p>"))
        XCTAssertNil(ClipboardSafeHTMLPreview.parse(""))
    }

    func testRejectsOversizedDocumentAndExcessiveNestingOrStyleRuns() {
        XCTAssertNil(ClipboardSafeHTMLPreview.parse(
            "<b>" + String(repeating: "A", count: 128 * 1024 + 1) + "</b>"
        ))
        XCTAssertNil(ClipboardSafeHTMLPreview.parse(
            String(repeating: "<b>", count: 34) + "x" +
            String(repeating: "</b>", count: 34)
        ))
        XCTAssertNil(ClipboardSafeHTMLPreview.parse(
            String(repeating: "<b>x</b> ", count: 513)
        ))
    }
}
