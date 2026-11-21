import Foundation
import XCTest
@testable import NexusCore

final class ClipboardRemoteWebTitlePolicyTests: XCTestCase {
    func testRequiresPublicHTTPSWithoutPrivateOrParameterizedLinks() {
        let allowed = [
            "https://www.apple.com/mac/",
            "https://en.wikipedia.org/wiki/Probability",
            "https://docs.swift.org/"
        ]
        for link in allowed {
            XCTAssertNotNil(ClipboardRemoteWebTitlePolicy.eligibleURL(link), link)
        }
        let rejected = [
            "http://www.apple.com",
            "https://localhost/test",
            "https://printer.local/",
            "https://device.internal/api",
            "https://server.lan/share",
            "https://127.0.0.1/",
            "https://192.168.1.22/",
            "https://[::1]/",
            "https://example.com/?token=secret",
            "https://example.com/#user",
            "https://someone:password@example.com/",
            "https://example.com:8443/",
            "https://example.test/",
            "ftp://example.com/",
            "javascript:alert(1)",
            "normal clipboard text"
        ]
        for link in rejected {
            XCTAssertNil(ClipboardRemoteWebTitlePolicy.eligibleURL(link), link)
        }
    }

    func testBoundedOfflineTitleExtractionAndUnicode() {
        let url = "https://en.wikipedia.org/wiki/Probability"
        let html = "<html><head><title>概率论 &amp; Statistics 😀</title></head></html>"
        XCTAssertEqual(
            ClipboardRemoteWebTitlePolicy.title(
                fromHTML: Data(html.utf8), copiedText: url
            ),
            "概率论 & Statistics 😀"
        )
        let invalid = [
            "<title><script>alert(1)</script></title>",
            "<script>document.title = 'Steal'</script>",
            "<title>broken",
            "<title>bad &#x3C;malicious&gt;</title>",
            "<title>line\nfeed</title>"
        ]
        for page in invalid {
            XCTAssertNil(ClipboardRemoteWebTitlePolicy.title(
                fromHTML: Data(page.utf8), copiedText: url
            ), page)
        }
        XCTAssertNil(ClipboardRemoteWebTitlePolicy.title(
            fromHTML: Data(repeating: 65,
                           count: ClipboardRemoteWebTitlePolicy.maximumHTMLBytes + 1),
            copiedText: url
        ))
        XCTAssertNil(ClipboardRemoteWebTitlePolicy.title(
            fromHTML: Data("<title>Same URL</title>".utf8),
            copiedText: "not a URL"
        ))
    }

    func testStaleCopyURLCannotReceiveDelayedFetchedTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        let original = "https://www.apple.com/mac/"
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 90,
                         clipboardText: original)
        let event = try XCTUnwrap(store.query(from: 0, to: 100).first)
        XCTAssertThrowsError(try store.recordLinkTitle(
            operationID: event.id, title: "Mac", expectedCopiedText:
                "https://different.example.com"
        ))
        XCTAssertNil(try store.linkTitle(operationID: event.id))
        try store.recordLinkTitle(
            operationID: event.id, title: "Mac",
            expectedCopiedText: original
        )
        XCTAssertEqual(try store.linkTitle(operationID: event.id), "Mac")
    }
}
