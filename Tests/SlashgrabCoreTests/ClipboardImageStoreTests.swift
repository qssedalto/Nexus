import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardImageStoreTests: XCTestCase {
    func testRepeatedImagesReuseOneBlobAndDeletionReclaimsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02])
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let store = try OperationStore(url: url)
        let first = try store.recordClipboardImage(data: image, thumbnail: thumbnail,
                                                   pasteboardType: "public.png", detectedTimeMS: 1000)
        let second = try store.recordClipboardImage(data: image, thumbnail: thumbnail,
                                                    pasteboardType: "public.png", detectedTimeMS: 1001)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try store.imageBlobCount(), 1)
        XCTAssertEqual(try store.imageThumbnail(operationID: first), thumbnail)
        XCTAssertEqual(try store.imageContent(operationID: second)?.data, image)
        XCTAssertEqual(try store.imageContent(operationID: second)?.pasteboardType, "public.png")
        let rows = try store.query(from: 1000, to: 1002)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.clipboardText == nil && $0.type == "image_copy" })
        XCTAssertEqual(rows.map { $0.items.first?.size }, [6, 6])
        XCTAssertTrue(try store.deleteOperation(id: first))
        XCTAssertEqual(try store.imageBlobCount(), 1)
        XCTAssertTrue(try store.deleteOperation(id: second))
        XCTAssertEqual(try store.imageBlobCount(), 0)
        XCTAssertNil(try store.imageContent(operationID: second))
    }

    func testMigratedStoreRetainsImageAndRejectsUnboundedPayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        var id = ""
        do {
            let store = try OperationStore(url: url)
            id = try store.recordClipboardImage(
                data: Data([1, 2, 3]), thumbnail: Data([7]),
                pasteboardType: "public.tiff", detectedTimeMS: 900
            )
            XCTAssertThrowsError(try store.recordClipboardImage(
                data: Data(repeating: 1, count: 8 * 1_024 * 1_024 + 1),
                thumbnail: Data([7]), pasteboardType: "public.png",
                detectedTimeMS: 901
            ))
            XCTAssertThrowsError(try store.recordClipboardImage(
                data: Data([1]), thumbnail: Data([1]),
                pasteboardType: "public.html", detectedTimeMS: 902
            ))
        }
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(try reopened.imageContent(operationID: id)?.data, Data([1, 2, 3]))
        XCTAssertEqual(try reopened.imageBlobCount(), 1)
        XCTAssertEqual(try reopened.pruneHistory(olderThan: Int64.max,
                                                 protectedIDs: []), 1)
        XCTAssertEqual(try reopened.imageBlobCount(), 0)
    }
}
