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

    func testPartialLegacyMigrationKeepsExistingColumnsAndRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE operations (
                id TEXT PRIMARY KEY, type TEXT NOT NULL, event_time_ms INTEGER,
                detected_time_ms INTEGER NOT NULL, completed_time_ms INTEGER,
                source_application TEXT, detection_method TEXT NOT NULL,
                status TEXT NOT NULL, target TEXT
            );
            INSERT INTO operations VALUES
                ('legacy-partial', 'copy', NULL, 1000, NULL, NULL, 'clipboard', 'clipboard_detected', '/tmp');
            PRAGMA user_version=1;
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try OperationStore(url: url)
        let entries = try store.query(from: 1000, to: 1001)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "legacy-partial")
        XCTAssertEqual(entries[0].target, "/tmp")
        XCTAssertNil(entries[0].completedTimeMS)
    }


    func testOperationSyncPrivacyAndAcknowledgements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("secret report.pdf")
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        try store.record(type: "path_copy", urls: [file], sourceApplication: "Nexus",
                         detectionMethod: "drop", detectedTimeMS: 3001,
                         completedTimeMS: 3002, clipboardText: "super private")
        let first = try store.pendingSync()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(try store.pendingSync().map(\.id), first.map(\.id))
        let redacted = SyncOperation(record: first[0], includePaths: false, includeText: false)
        let data = try JSONEncoder().encode(OperationSyncBatch(deviceID: "anonymous-device", operations: [redacted]))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(file.path))
        XCTAssertFalse(json.contains("super private"))
        XCTAssertTrue(json.contains("secret report.pdf"))
        XCTAssertEqual(redacted.items[0].source, nil)
        XCTAssertNil(redacted.clipboardText)
        let full = SyncOperation(record: first[0], includePaths: true, includeText: true)
        XCTAssertEqual(full.items[0].source, file.path)
        XCTAssertEqual(full.clipboardText, "super private")
        try store.markSynced(operationIDs: first.map(\.id))
        XCTAssertTrue(try store.pendingSync().isEmpty)
        XCTAssertEqual(try store.query(from: 3001, to: 3002).count, 1)
    }

    func testRemoteRestoreIsIdempotentAndDoesNotResync() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        let json = """
        {
          "operations": [{
            "device_id":"remote-Mac",
            "operation":{
              "id":"48a989b2-beaa-4acc-8124-d8968a68421b",
              "type":"copy", "detected_time_ms":5600,
              "detection_method":"clipboard", "status":"clipboard_detected",
              "items":[{"position":0,"name":"資料.heic","kind":"image","extension":"heic","size":32}]
            }
          }],
          "next_offset":null
        }
        """
        let page = try JSONDecoder().decode(RemoteOperationPage.self, from: Data(json.utf8))
        XCTAssertEqual(try store.importRemote(page.operations), 1)
        XCTAssertEqual(try store.importRemote(page.operations), 0)
        let history = try store.query(from: 5600, to: 5601)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].items[0].kind, "image")
        XCTAssertEqual(history[0].items[0].name, "資料.heic")
        XCTAssertTrue(try store.pendingSync().isEmpty)
    }


    func testPassivePasteRequestStoresNoContentOrFalseCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OperationStore(url: directory.appendingPathComponent("operations.sqlite"))
        try store.record(
            type: "paste_request", urls: [], sourceApplication: nil,
            detectionMethod: "quartz_shortcut", eventTimeMS: 1400,
            detectedTimeMS: 1403
        )
        let event = try XCTUnwrap(store.query(from: 1400, to: 1404).first)
        XCTAssertEqual(event.type, "paste_request")
        XCTAssertEqual(event.status, "paste_requested")
        XCTAssertEqual(event.eventTimeMS, 1400)
        XCTAssertEqual(event.detectedTimeMS, 1403)
        XCTAssertNil(event.completedTimeMS)
        XCTAssertNil(event.durationMS)
        XCTAssertNil(event.target)
        XCTAssertNil(event.clipboardText)
        XCTAssertNil(event.sourceApplication)
        XCTAssertTrue(event.items.isEmpty)
    }


    func testSingleDragDropWithSeveralTopLevelItemsHasOneOperationAndMeasuredDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("报告 \"2026\".pdf")
        let photo = root.appendingPathComponent("照片.heic")
        let folder = root.appendingPathComponent("Python 项目", isDirectory: true)
        try Data(count: 32).write(to: document)
        try Data(count: 64).write(to: photo)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))

        try store.record(type: "drop_copy", urls: [document, photo, folder],
                         sourceApplication: "Nexus", detectionMethod: "drop",
                         eventTimeMS: 7000, detectedTimeMS: 7004,
                         completedTimeMS: 7011,
                         clipboardText: "quoted path output")
        let entries = try store.query(from: 7000, to: 7012)
        XCTAssertEqual(entries.count, 1)
        let operation = try XCTUnwrap(entries.first)
        XCTAssertEqual(operation.type, "drop_copy")
        XCTAssertEqual(operation.detectionMethod, "drop")
        XCTAssertEqual(operation.items.count, 3)
        XCTAssertEqual(operation.eventTimeMS, 7000)
        XCTAssertEqual(operation.detectedTimeMS, 7004)
        XCTAssertEqual(operation.completedTimeMS, 7011)
        XCTAssertEqual(operation.durationMS, 11)
        XCTAssertEqual(operation.items[0].name, document.lastPathComponent)
        XCTAssertEqual(operation.items[0].source, document.path)
        XCTAssertEqual(operation.items[1].kind, "image")
        XCTAssertEqual(operation.items[1].size, 64)
        XCTAssertEqual(operation.items[2].kind, "folder")
        XCTAssertNil(operation.items[2].size)
        XCTAssertEqual(operation.items[2].source, folder.path)
    }


    func testBoundedRecentQueryAndOldPinnedUUIDLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        for index: Int64 in 1...240 {
            try store.record(type: "text_copy", urls: [], sourceApplication: nil,
                             detectionMethod: "clipboard", detectedTimeMS: index * 1000,
                             clipboardText: "snippet \(index)")
        }
        let recent = try store.query(from: 0, to: Int64.max, limit: 35)
        XCTAssertEqual(recent.count, 35)
        XCTAssertEqual(recent.first?.detectedTimeMS, 240_000)
        XCTAssertEqual(recent.last?.detectedTimeMS, 206_000)

        let oldest = try XCTUnwrap(store.query(from: 1000, to: 1001).first)
        XCTAssertFalse(recent.contains(where: { $0.id == oldest.id }))
        let favorite = try store.query(ids: [oldest.id, oldest.id, "not-an-id"])
        XCTAssertEqual(favorite.count, 1)
        XCTAssertEqual(favorite.first?.clipboardText, "snippet 1")
        XCTAssertTrue(try store.query(ids: []).isEmpty)
        XCTAssertEqual(try store.query(from: 0, to: Int64.max).count, 240)
    }

    func testBulkHistoryClearPreservesPinsCollectionsNewCopiesAndUnrelatedEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try OperationStore(url: directory.appendingPathComponent("bulk.sqlite"))
        let cutoff: Int64 = 1_796_000_000_000
        for index in 0..<13 {
            try store.record(
                type: "text_copy", urls: [], sourceApplication: nil,
                detectionMethod: "clipboard", detectedTimeMS: cutoff - 1_000 + Int64(index),
                clipboardText: "old-\(index)"
            )
        }
        let old = try store.query(from: 0, to: cutoff)
        let pinned = try XCTUnwrap(old.first { $0.clipboardText == "old-0" })
        let permanentlySaved = try XCTUnwrap(old.first { $0.clipboardText == "old-1" })
        let collection = try store.createCollection(named: "Do not delete")
        XCTAssertTrue(try store.addOperation(id: permanentlySaved.id, toCollection: collection.id))

        try store.record(
            type: "text_copy", urls: [], sourceApplication: nil,
            detectionMethod: "clipboard", detectedTimeMS: cutoff + 1,
            clipboardText: "copied-after-confirmation"
        )
        try store.record(
            type: "paste_request", urls: [], sourceApplication: nil,
            detectionMethod: "user_request", detectedTimeMS: cutoff - 1_000
        )

        // Small batches exercise the same repeated-delete code as a huge DB.
        let deleted = try await store.clearUnpinnedClipboardHistory(
            olderThan: cutoff, protectedIDs: [pinned.id], batchSize: 2
        )
        XCTAssertEqual(deleted, 11)
        let remaining = try store.query(from: 0, to: Int64.max)
        XCTAssertEqual(remaining.count, 4)
        XCTAssertTrue(remaining.contains { $0.id == pinned.id })
        XCTAssertTrue(remaining.contains { $0.id == permanentlySaved.id })
        XCTAssertTrue(remaining.contains { $0.clipboardText == "copied-after-confirmation" })
        XCTAssertEqual(remaining.filter { $0.type == "paste_request" }.count, 1)
        XCTAssertEqual(try store.collectionOperationIDs(collectionID: collection.id),
                       [permanentlySaved.id])
        let again = try await store.clearUnpinnedClipboardHistory(
            olderThan: cutoff, protectedIDs: [pinned.id], batchSize: 2
        )
        XCTAssertEqual(again, 0)
    }

    func testBulkHistoryClearContinuesPastOneHundredTransactions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try OperationStore(url: directory.appendingPathComponent("many.sqlite"))
        let cutoff: Int64 = 1_796_000_000_000
        for index in 0..<105 {
            try store.record(
                type: "text_copy", urls: [], sourceApplication: nil,
                detectionMethod: "clipboard", detectedTimeMS: cutoff - Int64(index + 1),
                clipboardText: "batch-\(index)"
            )
        }
        let deleted = try await store.clearUnpinnedClipboardHistory(
            olderThan: cutoff, protectedIDs: [], batchSize: 1
        )
        XCTAssertEqual(deleted, 105)
        XCTAssertTrue(try store.query(from: 0, to: Int64.max).isEmpty)
    }

}
