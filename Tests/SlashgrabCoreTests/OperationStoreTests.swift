import Foundation
import SQLite3
import XCTest
@testable import SlashgrabCore

final class OperationStoreTests: XCTestCase {
    func testBatchMetadataAndMillisecondRange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = directory.appendingPathComponent("图像.heic")
        try Data(repeating: 1, count: 100).write(to: image)
        let folder = directory.appendingPathComponent("Huge Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        let timestamp: Int64 = 1_795_163_532_125
        try store.record(type: "path_copy", urls: [image, folder], sourceApplication: "Nexus", detectionMethod: "drop", eventTimeMS: timestamp)

        let all = try store.query(from: 0, to: Int64.max)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].items.count, 2)
        XCTAssertEqual(all[0].items[0].source, image.path)
        XCTAssertEqual(all[0].items[0].size, 100)
        XCTAssertEqual(all[0].items[0].kind, "image")
        XCTAssertEqual(all[0].items[1].source, folder.path)
        XCTAssertNil(all[0].items[1].size)
        XCTAssertEqual(all[0].eventTimeMS, timestamp)
        XCTAssertEqual(try store.query(from: timestamp, to: timestamp + 1).count, 1)
        XCTAssertTrue(try store.query(from: timestamp + 1, to: timestamp + 2).isEmpty)
    }

    func testMigratesExistingDatabaseWithoutLosingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE operations (id TEXT PRIMARY KEY, type TEXT NOT NULL, event_time_ms INTEGER, detected_time_ms INTEGER NOT NULL, completed_time_ms INTEGER, source_application TEXT, detection_method TEXT NOT NULL, status TEXT NOT NULL); INSERT INTO operations VALUES ('old', 'path_copy', 100, 101, 102, 'Nexus', 'drop', 'clipboard_written'); PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try OperationStore(url: url)
        let history = try store.query(from: 100, to: 101)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].id, "old")
        XCTAssertNil(history[0].target)
    }
    func testClipboardTextIsSingleOperationWithObservedTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        let detected: Int64 = 1_795_163_532_126

        try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: detected,
                         clipboardText: "中文 copied text")
        let events = try store.query(from: detected, to: detected + 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "text_copy")
        XCTAssertEqual(events[0].detectedTimeMS, detected)
        XCTAssertNil(events[0].eventTimeMS)
        XCTAssertNil(events[0].completedTimeMS)
        XCTAssertNil(events[0].durationMS)
        XCTAssertEqual(events[0].status, "clipboard_detected")
        XCTAssertEqual(events[0].clipboardText, "中文 copied text")
        XCTAssertEqual(events[0].items.count, 1)
        XCTAssertEqual(events[0].items[0].kind, "text")
        XCTAssertNil(events[0].items[0].source)
        XCTAssertEqual(try store.query(from: detected + 1, to: detected + 2).count, 0)
    }

    func testCopiedImageWithoutFileURLStoresMetadataOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        try store.record(type: "image_copy", urls: [], sourceApplication: nil,
                         detectionMethod: "clipboard_type", detectedTimeMS: 1234)
        let events = try store.query(from: 1234, to: 1235)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].items.count, 1)
        XCTAssertEqual(events[0].items[0].kind, "image")
        XCTAssertNil(events[0].items[0].source)
        XCTAssertNil(events[0].items[0].size)
        XCTAssertNil(events[0].clipboardText)
        XCTAssertNil(events[0].completedTimeMS)
    }

    func testFileClipboardReferenceDoesNotClaimCompletedTransfer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.pvm")
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        try store.record(type: "copy", urls: [file], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 4567)
        let events = try store.query(from: 4567, to: 4568)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].status, "clipboard_detected")
        XCTAssertNil(events[0].completedTimeMS)
        XCTAssertNil(events[0].durationMS)
        XCTAssertEqual(events[0].items[0].source, file.path)
    }

}
