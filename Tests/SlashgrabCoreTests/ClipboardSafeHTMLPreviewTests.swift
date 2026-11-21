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

    func testHeadingsListsAndQuotesHaveSafePlainTextStructure() throws {
        let preview = try XCTUnwrap(ClipboardSafeHTMLPreview.parse(
            "<h2>报告😀</h2><ul><li>第一项</li><li><strong>第二项</strong></li></ul>"
                + "<blockquote><em>注释</em></blockquote>"
        ))
        XCTAssertEqual(preview.text, "报告😀\n第一项\n第二项\n注释")
        XCTAssertTrue(preview.runs.contains {
            $0.bold && $0.locationUTF16 == 0
                && $0.lengthUTF16 == "报告😀".utf16.count
        })
        XCTAssertTrue(preview.runs.contains { $0.italic })
        for run in preview.runs {
            XCTAssertLessThanOrEqual(
                run.locationUTF16 + run.lengthUTF16,
                preview.text.utf16.count
            )
        }
    }

    func testSafePreformattedAndSectionTagsDoNotLoadResources() throws {
        let preview = try XCTUnwrap(ClipboardSafeHTMLPreview.parse(
            "<section><h3>代码</h3><pre><code>let n = 42</code></pre></section>"
        ))
        XCTAssertEqual(preview.text, "代码\nlet n = 42")
        XCTAssertTrue(preview.runs.contains { $0.bold })
        let invalid = [
            "<li><b>孤立的项目</b></li>",
            "<h2 onclick=alert(1)>标题</h2>",
            "<ul><li>x</ul></li>",
            "<blockquote cite='https://example.com'><b>x</b></blockquote>",
            "<pre><script>alert(1)</script></pre>",
            "<section><img src='https://example.com/pixel'></section>"
        ]
        for html in invalid {
            XCTAssertNil(ClipboardSafeHTMLPreview.parse(html), html)
        }
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
