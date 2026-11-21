import XCTest
@testable import SlashgrabCore

final class ClipboardTextPreviewTests: XCTestCase {
    func testHttpAndHttpsLinkPreviewUsesOnlyHostname() {
        XCTAssertEqual(
            ClipboardTextPreview.classify(" https://example.org/路径?x=1 "),
            .webLink(host: "example.org")
        )
        XCTAssertEqual(
            ClipboardTextPreview.classify("http://localhost:8080/report"),
            .webLink(host: "localhost")
        )
    }

    func testNeverTreatsCredentialURLsScriptsOrMultilineAsLinks() {
        XCTAssertEqual(ClipboardTextPreview.classify("javascript:alert(1)"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify("file:///private/secret"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify("https://user:pw@example.com/"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify("https://example.com\nand another link"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify("hello https://example.org"), .plain)
    }

    func testExplicitFencedCodeOnlyAndChineseTextPreserved() {
        let fenced = "```swift\nprint(\"你好世界\")\n```"
        XCTAssertEqual(ClipboardTextPreview.classify(fenced), .fencedCode(language: "swift"))
        XCTAssertEqual(
            ClipboardTextPreview.classify("```\nlet x = 1\n```"),
            .fencedCode(language: nil)
        )
        XCTAssertEqual(ClipboardTextPreview.classify("let x = 1"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify("你好世界"), .plain)
        XCTAssertEqual(ClipboardTextPreview.classify(""), .plain)
    }

    func testUntrustedOrOversizedLanguageLabelIsNotRendered() {
        XCTAssertEqual(
            ClipboardTextPreview.classify("```<script>\nprint(1)\n```"),
            .fencedCode(language: nil)
        )
    }
}
