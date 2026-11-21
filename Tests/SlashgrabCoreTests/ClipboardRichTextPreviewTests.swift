import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardRichTextPreviewTests: XCTestCase {
    func testBoundedStyleRunAndUTF16Safety() {
        let run = ClipboardRichTextRun(
            locationUTF16: 0, lengthUTF16: 2,
            bold: true, italic: false, underline: false
        )
        XCTAssertNotNil(ClipboardRichTextPreview(text: "😀A", runs: [run]))
        XCTAssertNil(ClipboardRichTextPreview(
            text: "😀", runs: [
                ClipboardRichTextRun(locationUTF16: 2, lengthUTF16: 1,
                                     bold: true, italic: false, underline: false)
            ]
        ))
        XCTAssertNil(ClipboardRichTextPreview(
            text: "你好", runs: [
                ClipboardRichTextRun(locationUTF16: -1, lengthUTF16: 2,
                                     bold: true, italic: false, underline: false)
            ]
        ))
        XCTAssertNil(ClipboardRichTextPreview(
            text: "test", runs: [
                ClipboardRichTextRun(locationUTF16: 0, lengthUTF16: 4,
                                     bold: false, italic: false, underline: false)
            ]
        ))
        XCTAssertNil(ClipboardRichTextPreview(text: "plain", runs: []))
    }

    func testFormattedCopyPersistsAcrossRestartAndCascadesOnDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("operations.sqlite")
        let preview = try XCTUnwrap(ClipboardRichTextPreview(
            text: "带格式的内容",
            runs: [ClipboardRichTextRun(
                locationUTF16: 0, lengthUTF16: 3,
                bold: true, italic: false, underline: true
            )]
        ))
        var id: String = ""
        do {
            let store = try OperationStore(url: url)
            id = try store.recordRichText(preview, detectedTimeMS: 123)
            XCTAssertEqual(try store.query(from: 0, to: 200).first?.clipboardText,
                           "带格式的内容")
            XCTAssertEqual(try store.richTextPreview(operationID: id), preview)
        }
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(try reopened.richTextPreview(operationID: id), preview)
        XCTAssertTrue(try reopened.deleteOperation(id: id))
        XCTAssertNil(try reopened.richTextPreview(operationID: id))
    }

    func testFormattingIsNeverIncludedInUnrelatedTextHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard",
                         detectedTimeMS: 1, clipboardText: "plain")
        let id = try XCTUnwrap(store.query(from: 0, to: 3).first?.id)
        XCTAssertNil(try store.richTextPreview(operationID: id))
    }
}
