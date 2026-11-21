import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCollectionDropPolicyTests: XCTestCase {
    func testOnlyExistingLocalCardsAndCollectionsAreAccepted() {
        let card = UUID().uuidString
        let collection = UUID().uuidString
        let loaded: Set<String> = [card]
        let available: Set<String> = [collection]
        XCTAssertTrue(ClipboardCollectionDropPolicy.accepts(
            draggedID: card, loadedOperationIDs: loaded,
            targetCollectionID: collection, availableCollectionIDs: available))
        XCTAssertFalse(ClipboardCollectionDropPolicy.accepts(
            draggedID: "external clipboard text", loadedOperationIDs: loaded,
            targetCollectionID: collection, availableCollectionIDs: available))
        XCTAssertFalse(ClipboardCollectionDropPolicy.accepts(
            draggedID: UUID().uuidString, loadedOperationIDs: loaded,
            targetCollectionID: collection, availableCollectionIDs: available))
        XCTAssertFalse(ClipboardCollectionDropPolicy.accepts(
            draggedID: card, loadedOperationIDs: loaded,
            targetCollectionID: UUID().uuidString, availableCollectionIDs: available))
    }

    func testAddingToAnotherCollectionDoesNotChangeExistingMembershipOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("history.sqlite"))
        for index: Int64 in 1...3 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard", detectedTimeMS: index,
                             clipboardText: "snippet \(index)")
        }
        let cards = try store.query(from: 0, to: 4).map(\.id)
        let first = try store.createCollection(named: "收藏 A")
        let second = try store.createCollection(named: "收藏 B")
        XCTAssertTrue(try store.addOperation(id: cards[0], toCollection: first.id))
        XCTAssertTrue(try store.addOperation(id: cards[1], toCollection: first.id))
        XCTAssertTrue(try store.addOperation(id: cards[0], toCollection: second.id))
        XCTAssertFalse(try store.addOperation(id: cards[0], toCollection: second.id))
        XCTAssertEqual(try store.collectionOperationIDs(collectionID: first.id),
                       [cards[0], cards[1]])
        XCTAssertEqual(try store.collectionOperationIDs(collectionID: second.id),
                       [cards[0]])
    }
}
