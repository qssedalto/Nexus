import Foundation
import XCTest
@testable import NexusCore

final class ClipboardCollectionsTests: XCTestCase {
    func testCollectionMembershipOrderAndDurability() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("operations.sqlite")

        let collectionID: String
        let ids: [String]
        do {
            let store = try OperationStore(url: url)
            for index: Int64 in 1...3 {
                try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                                 detectionMethod: "clipboard", detectedTimeMS: index * 1000,
                                 clipboardText: "snippet \(index)")
            }
            ids = try store.query(from: 0, to: 4000)
                .sorted { $0.detectedTimeMS < $1.detectedTimeMS }.map(\.id)
            let collection = try store.createCollection(named: "工作片段")
            collectionID = collection.id
            XCTAssertEqual(try store.listCollections().map(\.name), ["工作片段"])
            XCTAssertThrowsError(try store.createCollection(named: "工作片段"))
            XCTAssertTrue(try store.addOperation(id: ids[0], toCollection: collectionID))
            XCTAssertTrue(try store.addOperation(id: ids[1], toCollection: collectionID))
            XCTAssertTrue(try store.addOperation(id: ids[2], toCollection: collectionID))
            XCTAssertFalse(try store.addOperation(id: ids[0], toCollection: collectionID))
            XCTAssertEqual(try store.collectionOperationIDs(collectionID: collectionID), ids)

            XCTAssertTrue(try store.moveOperation(id: ids[2], before: ids[0], inCollection: collectionID))
            XCTAssertEqual(try store.collectionOperationIDs(collectionID: collectionID),
                           [ids[2], ids[0], ids[1]])
            XCTAssertTrue(try store.moveOperation(id: ids[2], before: nil, inCollection: collectionID))
            XCTAssertEqual(try store.collectionOperationIDs(collectionID: collectionID),
                           [ids[0], ids[1], ids[2]])
        }

        // Every collection and ordering entry is saved in SQLite, not a
        // transient UserDefaults-only pin list.
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(try reopened.listCollections().map(\.id), [collectionID])
        XCTAssertEqual(try reopened.collectionOperationIDs(collectionID: collectionID), ids)
        XCTAssertTrue(try reopened.removeOperation(id: ids[1], fromCollection: collectionID))
        XCTAssertEqual(try reopened.collectionOperationIDs(collectionID: collectionID),
                       [ids[0], ids[2]])
        XCTAssertFalse(try reopened.removeOperation(id: ids[1], fromCollection: collectionID))
    }

    func testPermanentCollectionsProtectHistoryFromCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        for i: Int64 in 1...3 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard", detectedTimeMS: i * 1000,
                             clipboardText: "saved \(i)")
        }
        let entries = try store.query(from: 0, to: 4000)
            .sorted { $0.detectedTimeMS < $1.detectedTimeMS }
        let permanent = try store.createCollection(named: "永久剪贴板")
        XCTAssertTrue(try store.addOperation(id: entries[0].id, toCollection: permanent.id))
        XCTAssertTrue(try store.addOperation(id: entries[1].id, toCollection: permanent.id))
        XCTAssertEqual(try store.pruneHistory(olderThan: Int64.max), 1)
        XCTAssertEqual(Set(try store.query(from: 0, to: 4000).map(\.id)),
                       Set([entries[0].id, entries[1].id]))
        XCTAssertEqual(try store.pruneHistory(keepingNewest: 1), 0)

        // Deleting the collection does not delete its contents. Those
        // records become eligible for ordinary retention thereafter.
        XCTAssertTrue(try store.deleteCollection(id: permanent.id))
        XCTAssertTrue(try store.listCollections().isEmpty)
        XCTAssertEqual(try store.query(from: 0, to: 4000).count, 2)
        XCTAssertEqual(try store.pruneHistory(olderThan: Int64.max), 2)
        XCTAssertTrue(try store.query(from: 0, to: 4000).isEmpty)
    }

    func testDeletingOperationCascadesMembershipButKeepsCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 1000,
                         clipboardText: "to be deleted")
        let id = try XCTUnwrap(store.query(from: 1000, to: 1001).first?.id)
        let collection = try store.createCollection(named: "Code")
        XCTAssertTrue(try store.addOperation(id: id, toCollection: collection.id))
        XCTAssertTrue(try store.deleteOperation(id: id))
        XCTAssertTrue(try store.collectionOperationIDs(collectionID: collection.id).isEmpty)
        XCTAssertEqual(try store.listCollections().map(\.name), ["Code"])
    }

    func testRenamingCollectionPreservesStableIDMembersAndOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("collections.sqlite")
        let collectionID: String
        let memberIDs: [String]
        do {
            let store = try OperationStore(url: url)
            let original = try store.createCollection(named: "项目")
            _ = try store.createCollection(named: "收藏")
            collectionID = original.id
            for index in 0..<3 {
                try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                                 detectionMethod: "clipboard",
                                 detectedTimeMS: Int64(index + 1),
                                 clipboardText: "item \(index)")
            }
            memberIDs = try store.query(from: 0, to: Int64.max).map(\.id)
            for id in memberIDs {
                XCTAssertTrue(try store.addOperation(id: id, toCollection: original.id))
            }
            XCTAssertTrue(try store.renameCollection(id: original.id, to: "  新项目  "))
            XCTAssertEqual(try store.listCollections().first {
                $0.id == original.id
            }?.name, "新项目")
            XCTAssertEqual(try store.collectionOperationIDs(collectionID: original.id), memberIDs)
            XCTAssertThrowsError(try store.renameCollection(id: original.id, to: "收藏"))
            XCTAssertThrowsError(try store.renameCollection(id: original.id, to: "  "))
            XCTAssertThrowsError(try store.renameCollection(id: original.id, to: String(repeating: "字", count: 51)))
            XCTAssertFalse(try store.renameCollection(id: "missing", to: "Nothing"))
        }
        let reopened = try OperationStore(url: url)
        XCTAssertEqual(try reopened.listCollections().first {
            $0.id == collectionID
        }?.name, "新项目")
        XCTAssertEqual(try reopened.collectionOperationIDs(collectionID: collectionID), memberIDs)
    }

}
