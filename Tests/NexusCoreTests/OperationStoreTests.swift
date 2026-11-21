import Foundation
import SQLite3
import XCTest
@testable import NexusCore

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
}
