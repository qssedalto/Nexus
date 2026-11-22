import Foundation
import XCTest
@testable import NexusCore

final class ClipboardLinkTitleTests: XCTestCase {
    func testOfflineLinkTitleSanitizationAndPrivacyBounds() {
        XCTAssertEqual(ClipboardLinkTitlePolicy.sanitized(
            "  苹果开发者文档 📖  ", copiedText: "https://developer.apple.com/"
        ), "苹果开发者文档 📖")
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            "Any title", copiedText: "javascript:alert(1)"
        ))
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            "Any title", copiedText: "not a standalone link https://example.com"
        ))
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            "https://example.org", copiedText: "https://example.org"
        ))
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            "hidden\u{0000}value", copiedText: "https://example.org"
        ))
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            String(repeating: "a", count: 161),
            copiedText: "https://example.org"
        ))
        XCTAssertNil(ClipboardLinkTitlePolicy.sanitized(
            nil, copiedText: "https://example.org"
        ))
    }

    func testLocalURLTitlePersistsAcrossRestartAndDeletesWithItsCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        var operationID = ""
        do {
            let store = try OperationStore(url: url)
            operationID = try store.recordTextCopy(
                "https://example.org/文章", detectedTimeMS: 100
            )
            XCTAssertNil(try store.linkTitle(operationID: operationID))
            try store.recordLinkTitle(
                operationID: operationID, title: "  本地复制的标题  "
            )
            XCTAssertEqual(try store.linkTitle(operationID: operationID),
                           "本地复制的标题")
            try store.recordLinkTitle(operationID: operationID, title: "新标题")
            XCTAssertEqual(try store.linkTitle(operationID: operationID), "新标题")
        }
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(try reopened.linkTitle(operationID: operationID), "新标题")
        XCTAssertTrue(try reopened.deleteOperation(id: operationID))
        XCTAssertNil(try reopened.linkTitle(operationID: operationID))
    }

    func testCannotAttachURLTitleToUnrelatedTextOrMissingOperation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        let plain = try store.recordTextCopy("Some normal text", detectedTimeMS: 1)
        XCTAssertThrowsError(
            try store.recordLinkTitle(operationID: plain, title: "Not a URL")
        )
        XCTAssertNil(try store.linkTitle(operationID: plain))
        XCTAssertThrowsError(
            try store.recordLinkTitle(
                operationID: UUID().uuidString, title: "Orphan title"
            )
        )
    }
}
