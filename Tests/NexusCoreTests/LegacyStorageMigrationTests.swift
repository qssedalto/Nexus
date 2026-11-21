import Foundation
import SQLite3
import XCTest
@testable import NexusCore

final class LegacyStorageMigrationTests: XCTestCase {
    func testSQLiteMigrationPreservesRowsIncludingUncheckpointedWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexusLegacyMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldURL = directory.appendingPathComponent("NexusOperations.sqlite")
        let newURL = directory.appendingPathComponent("new.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(oldURL.path, &database), SQLITE_OK)
        guard let database else { XCTFail("Could not open test database"); return }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES('preserved')", nil, nil, nil), SQLITE_OK)

        // Keep original connection open to exercise copying data from a live WAL-mode database.
        XCTAssertTrue(SharedSettings.backupSQLiteIfAbsent(from: oldURL, to: newURL))
        XCTAssertFalse(SharedSettings.backupSQLiteIfAbsent(from: oldURL, to: newURL))

        var migrated: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(newURL.path, &migrated, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        guard let migrated else { sqlite3_close(database); XCTFail("Could not inspect migrated database"); return }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(migrated, "SELECT value FROM items", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        if let statement, let value = sqlite3_column_text(statement, 0) {
            XCTAssertEqual(String(cString: value), "preserved")
        } else {
            XCTFail("Missing migrated value")
        }
        sqlite3_finalize(statement)
        sqlite3_close(migrated)
        sqlite3_close(database)
    }

    func testMissingSourceNeverCreatesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexusLegacyMissing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("new.sqlite")
        XCTAssertFalse(SharedSettings.backupSQLiteIfAbsent(
            from: directory.appendingPathComponent("not-present.sqlite"),
            to: target
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
