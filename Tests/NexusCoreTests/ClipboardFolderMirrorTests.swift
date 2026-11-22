import Foundation
import XCTest
@testable import NexusCore

final class ClipboardFolderMirrorTests: XCTestCase {
    func testCopiesFilesAndDirectoryWithoutSizeGateOrCollision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("sample.bin")
        let bytes = Data(repeating: 0x5A, count: 9 * 1_024 * 1_024)
        try bytes.write(to: file)
        let nested = source.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "nested".write(to: nested.appendingPathComponent("note.txt"),
                           atomically: true, encoding: .utf8)
        let first = try ClipboardFolderMirror.save(.files([file, nested]), to: destination)
        let second = try ClipboardFolderMirror.save(.files([file]), to: destination)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("1 sample.bin")), bytes)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("2 Folder/note.txt"), encoding: .utf8), "nested")
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("1 sample.bin")), bytes)
    }

    func testTextImageAndCancellationDoNotLeavePartialFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = try ClipboardFolderMirror.save(.text("完整文本\n第二行"), to: folder)
        XCTAssertEqual(try String(contentsOf: text.appendingPathComponent("Text.txt"), encoding: .utf8), "完整文本\n第二行")
        let image = try ClipboardFolderMirror.save(.image(Data([1,2,3]), extensionName: "png"), to: folder)
        XCTAssertEqual(try Data(contentsOf: image.appendingPathComponent("Image.png")), Data([1,2,3]))
        XCTAssertThrowsError(try ClipboardFolderMirror.save(.text("cancel"), to: folder,
                                                           cancelled: { true }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
    }

    func testCannotCopyAncestorOfSelectedFolderIntoItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedFolder = root.appendingPathComponent("NexusClipboardSync")
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("note.txt")
        try "original".write(to: original, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ClipboardFolderMirror.save(.files([root]), to: selectedFolder))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selectedFolder.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }

    func testRejectsSymlinkToSelectedFolderAsSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedFolder = root.appendingPathComponent("NexusClipboardSync")
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selectedFolder)

        XCTAssertThrowsError(try ClipboardFolderMirror.save(.files([alias]), to: selectedFolder))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selectedFolder.path).isEmpty)
    }


    func testStreamingCopyReportsProgressAndCanCancelDuringLargeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("large.bin")
        let folder = root.appendingPathComponent("mirror")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = Data(repeating: 0x2A, count: 13 * 1_048_576)
        try content.write(to: source)
        let recorder = MirrorCopyProgressRecorder()
        XCTAssertThrowsError(try ClipboardFolderMirror.save(
            .files([source]), to: folder,
            cancelled: { recorder.shouldCancel },
            progress: { copied, total in recorder.record(copied: copied, total: total) }
        )) { error in
            guard case ClipboardFolderMirror.MirrorError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertGreaterThan(recorder.copied, 0)
        XCTAssertEqual(recorder.total, Int64(content.count))
        XCTAssertLessThan(recorder.copied, recorder.total)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), content)
    }

    func testNestedFolderPreservesHiddenFilesAndReportsAllBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("folder")
        let nested = source.appendingPathComponent("nested")
        let folder = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x3B, count: 2_097_152).write(
            to: nested.appendingPathComponent(".hidden.bin"))
        try "hello".write(to: source.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)
        let recorder = MirrorCopyProgressRecorder()
        let output = try ClipboardFolderMirror.save(
            .files([source]), to: folder,
            progress: { copied, total in recorder.record(copied: copied, total: total) }
        )
        XCTAssertEqual(recorder.total, 2_097_157)
        XCTAssertEqual(recorder.copied, recorder.total)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(
            "1 folder/nested/.hidden.bin")).count, 2_097_152)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(
            "1 folder/readme.txt"), encoding: .utf8), "hello")
    }

    func testRTFMirrorRetainsOriginalPublicRichTextAndPlainText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data(("{\\rtf1\\ansi Sample bold text}").utf8)
        let out = try ClipboardFolderMirror.save(
            .richText(text: "Sample bold text", rtf: original), to: folder
        )
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("Rich Text.rtf")), original)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Text.txt"),
                                  encoding: .utf8), "Sample bold text")
    }

    func testHTMLMirrorPreservesPublicHTMLBytesAndPlainTextFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Data("<b>hello</b> &amp; <em>world</em>".utf8)
        let output = try ClipboardFolderMirror.save(
            .html(text: "hello & world", html: original), to: folder
        )
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("Rich Text.html")), original)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Text.txt"),
                                  encoding: .utf8), "hello & world")
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: output.path)),
            Set(["Rich Text.html", "Text.txt"])
        )
    }

    func testHTMLMirrorCancellationLeavesNoPartialDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let state = RichTextCancellationState()
        XCTAssertThrowsError(try ClipboardFolderMirror.save(
            .html(text: "hello", html: Data("<b>hello</b>".utf8)),
            to: folder, cancelled: { state.isCancelled },
            progress: { _, _ in state.cancel() }
        )) { error in
            guard case ClipboardFolderMirror.MirrorError.cancelled = error else {
                return XCTFail("Expected cancelled, received \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }


    func testDetectsInterruptedCopiesWithoutDeletingUserFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let interrupted = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)
        try "unfinished".write(
            to: interrupted.appendingPathComponent("data.bin"), atomically: true, encoding: .utf8
        )
        let normal = folder.appendingPathComponent("visible.partial")
        try FileManager.default.createDirectory(at: normal, withIntermediateDirectories: false)
        let other = folder.appendingPathComponent(".\(UUID().uuidString).partial")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: interrupted)

        XCTAssertEqual(try ClipboardFolderMirror.interruptedCopies(in: folder), [interrupted])
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: normal.path))
    }

}


private final class MirrorCopyProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writtenBytes: Int64 = 0
    private var expectedBytes: Int64 = 0
    var copied: Int64 { lock.withLock { writtenBytes } }
    var total: Int64 { lock.withLock { expectedBytes } }
    var shouldCancel: Bool { lock.withLock { writtenBytes >= 4 * 1_048_576 } }

    func record(copied: Int64, total: Int64) {
        lock.withLock {
            writtenBytes = copied
            expectedBytes = total
        }
    }

}

private final class RichTextCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
