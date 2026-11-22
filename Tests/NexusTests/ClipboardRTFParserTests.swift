import AppKit
import Foundation
import Testing
@testable import Nexus
@testable import NexusCore

@Suite("Sanitized clipboard RTF")
@MainActor
struct ClipboardRTFParserTests {
    @Test("Bold style survives safe RTF conversion without original document")
    func preservesOnlySafeTypography() throws {
        let source = NSMutableAttributedString(string: "Bold 你好")
        source.addAttribute(
            .font, value: NSFont.boldSystemFont(ofSize: 14),
            range: NSRange(location: 0, length: 4)
        )
        let data = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let result = try #require(ClipboardRTFParser.sanitizedPreview(from: data))
        #expect(result.text == "Bold 你好")
        #expect(result.runs.contains(where: { $0.bold && $0.lengthUTF16 >= 4 }))
        #expect(result.runs.count <= 512)
    }

    @Test("RTF conversion fails closed on oversized malformed data")
    func boundsAndMalformedContent() {
        #expect(ClipboardRTFParser.sanitizedPreview(from: Data()) == nil)
        #expect(ClipboardRTFParser.sanitizedPreview(
            from: Data(repeating: 0x41, count: 128 * 1024 + 1)
        ) == nil)
        #expect(ClipboardRTFParser.sanitizedPreview(
            from: Data("not an RTF document".utf8)
        ) == nil)
    }
}
