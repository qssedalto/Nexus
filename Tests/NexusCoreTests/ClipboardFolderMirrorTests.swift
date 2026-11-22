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

}
