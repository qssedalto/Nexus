import Foundation
import SQLite3
import XCTest
@testable import SlashgrabCore

final class ClipboardSearchScaleTests: XCTestCase {
    /// CI seeds 30k synthetic history rows inside one transaction. Set
    /// NEXUS_BENCHMARK_HISTORY_100K=1 to profile 100k on an isolated Mac.
    /// Timings are diagnostics, not manufactured performance guarantees.
    func testIndexedThirtyThousandRowHistoryAndOptionalHundredThousand() throws {
        let count = ProcessInfo.processInfo.environment[
            "NEXUS_BENCHMARK_HISTORY_100K"
        ] == "1" ? 100_000 : 30_000
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let store = try OperationStore(url: url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let handle else {
            throw NSError(domain: "sqlite.open", code: 1)
        }
        defer { sqlite3_close(handle) }

        var plan: OpaquePointer?
        let indexQuery = """
            SELECT name FROM sqlite_master WHERE type='index'
            AND name IN ('operations_clipboard_time_id',
                         'operation_items_kind_by_operation')
            """
        XCTAssertEqual(sqlite3_prepare_v2(handle, indexQuery, -1, &plan, nil), SQLITE_OK)
        var found: Set<String> = []
        while sqlite3_step(plan) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(plan, 0) {
                let bytes = UnsafeBufferPointer(
                    start: ptr, count: Int(sqlite3_column_bytes(plan, 0))
                )
                found.insert(String(decoding: bytes, as: UTF8.self))
            }
        }
        sqlite3_finalize(plan)
        XCTAssertEqual(found, [
            "operations_clipboard_time_id",
            "operation_items_kind_by_operation"
        ])

        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var insert: OpaquePointer?
        let sql = """
            INSERT INTO operations
            (id,type,event_time_ms,detected_time_ms,completed_time_ms,
             source_application,detection_method,status,target,duration_ms,clipboard_text)
            VALUES (?,'text_copy',NULL,?,NULL,NULL,'benchmark','clipboard_detected',
                    NULL,NULL,?)
            """
        XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &insert, nil), SQLITE_OK)
        guard let insert else { XCTFail("Unable to prepare insert"); return }
        defer { sqlite3_finalize(insert) }
        for i in 0..<count {
            sqlite3_reset(insert)
            sqlite3_clear_bindings(insert)
            let id = String(format: "benchmark-%06d", i)
            let message = i.isMultiple(of: 100)
                ? "中文 needle \(i)"
                : "Synthetic ordinary clipboard sample \(i)"
            id.withCString {
                _ = sqlite3_bind_text(
                    insert, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            sqlite3_bind_int64(insert, 2, Int64(i + 1))
            message.withCString {
                _ = sqlite3_bind_text(
                    insert, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            if sqlite3_step(insert) != SQLITE_DONE {
                XCTFail("Failed seeding synthetic clipboard row \(i)")
                break
            }
        }
        XCTAssertEqual(sqlite3_exec(handle, "COMMIT", nil, nil, nil), SQLITE_OK)

        let start = ProcessInfo.processInfo.systemUptime
        let latest = try store.searchClipboard(query: "", limit: 200)
        let latestElapsed = ProcessInfo.processInfo.systemUptime - start
        let deepStart = ProcessInfo.processInfo.systemUptime
        let deepOffset = min(count - 200, 50_000)
        let older = try store.searchClipboard(
            query: "", limit: 200, offset: deepOffset
        )
        let deepElapsed = ProcessInfo.processInfo.systemUptime - deepStart
        let literalStart = ProcessInfo.processInfo.systemUptime
        let matches = try store.searchClipboard(
            query: "中文 needle", limit: 200
        )
        let literalElapsed = ProcessInfo.processInfo.systemUptime - literalStart
        XCTAssertEqual(latest.count, 200)
        XCTAssertEqual(older.count, 200)
        XCTAssertEqual(matches.count, 200)
        XCTAssertEqual(latest.first?.clipboardText,
                       "Synthetic ordinary clipboard sample \(count - 1)")
        XCTAssertEqual(
            older.last?.id,
            String(format: "benchmark-%06d", count - deepOffset - 200)
        )
        XCTAssertEqual(Set(latest.map(\.id)).intersection(older.map(\.id)).count, 0)
        print(String(format:
            "NEXUS_CLIPBOARD_BENCH rows=%d latest200=%.4fs deep200=%.4fs CJK200=%.4fs",
            count, latestElapsed, deepElapsed, literalElapsed
        ))
    }
}
