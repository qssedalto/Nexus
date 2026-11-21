import Foundation
import XCTest
@testable import NexusCore

final class ClipboardFilePreviewPolicyTests: XCTestCase {
    func testLocallyAvailableFileCanBePreviewedWithoutReadingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("图片 🖼️.png")
        try Data(repeating: 42, count: 100).write(to: file)
        XCTAssertEqual(
            ClipboardFilePreviewPolicy.eligibleLocalURL(path: file.path)?.path,
            file.path
        )
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(
            path: file.path, maximumBytes: 99
        ))
        XCTAssertNotNil(ClipboardFilePreviewPolicy.eligibleLocalURL(
            path: file.path, maximumBytes: 100
        ))
    }

    func testRejectsSymlinkDirectoryUnknownTypeAndMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.pdf")
        try Data([1, 2, 3]).write(to: file)
        let symlink = root.appendingPathComponent("shortcut.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        let noExtension = root.appendingPathComponent("secret")
        try Data([1]).write(to: noExtension)
        let directory = root.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: symlink.path))
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: directory.path))
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: noExtension.path))
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: file.path + ".missing"))
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: "https://example.com/image.png"))
    }

    func testRejectsCloudStoragePathsBeforeTouchingProvider() throws {
        let path = "/Users/example/Library/CloudStorage/OneDrive-Example/photo.jpg"
        XCTAssertNil(ClipboardFilePreviewPolicy.eligibleLocalURL(path: path))
    }
}
