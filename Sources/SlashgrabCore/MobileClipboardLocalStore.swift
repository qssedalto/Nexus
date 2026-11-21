import Foundation
import SQLite3

/// iOS/iPadOS explicit clipboard imports remain usable with CloudKit disabled.
/// The local store never observes UIPasteboard and never sends any network
/// requests. Its contents do not enter the CloudKit journal without consent.
public struct MobileLocalClipboardEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let detectedTimeMS: Int64
    public let text: String

    public init(id: String, detectedTimeMS: Int64, text: String) {
        self.id = id
        self.detectedTimeMS = detectedTimeMS
        self.text = text
    }
}

public final class MobileClipboardLocalStore: @unchecked Sendable {
    public enum Error: Swift.Error {
        case database, invalidText, write
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    public static let maximumTextBytes = 64 * 1_024
    public static let maximumEntries = 500

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw Error.database
        }
        handle = database
        sqlite3_busy_timeout(handle, 3_000)
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("""
                CREATE TABLE IF NOT EXISTS mobile_local_clipboard (
                    id TEXT PRIMARY KEY,
                    detected_ms INTEGER NOT NULL,
                    content TEXT NOT NULL
                )
                """)
            try exec("""
                CREATE INDEX IF NOT EXISTS mobile_local_clipboard_order
                ON mobile_local_clipboard(detected_ms DESC,id DESC)
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    public func recordText(
        _ text: String, detectedTimeMS: Int64
    ) throws -> MobileLocalClipboardEntry {
        guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes,
              detectedTimeMS >= 0 else { throw Error.invalidText }
        let entry = MobileLocalClipboardEntry(
            id: UUID().uuidString, detectedTimeMS: detectedTimeMS, text: text
        )
        lock.lock()
        defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("""
                INSERT INTO mobile_local_clipboard(id,detected_ms,content)
                VALUES(?,?,?)
                """)
            defer { sqlite3_finalize(stmt) }
            bind(entry.id, in: stmt, at: 1)
            sqlite3_bind_int64(stmt, 2, entry.detectedTimeMS)
            bind(entry.text, in: stmt, at: 3)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.write }
            try pruneLocked()
            try exec("COMMIT")
            return entry
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func recent(limit: Int = 100) throws -> [MobileLocalClipboardEntry] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT id,detected_ms,content
            FROM mobile_local_clipboard
            ORDER BY detected_ms DESC,id DESC LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(1, min(limit, 500))))
        var items: [MobileLocalClipboardEntry] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let id = value(stmt, 0), let content = value(stmt, 2) else {
                throw Error.database
            }
            items.append(MobileLocalClipboardEntry(
                id: id, detectedTimeMS: sqlite3_column_int64(stmt, 1),
                text: content
            ))
        }
        return items
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("DELETE FROM mobile_local_clipboard WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        bind(id, in: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.write }
        return sqlite3_changes(handle) > 0
    }

    /// The retention cap is intentionally bounded on mobile. This does not
    /// remove CloudKit private-zone content already synchronized elsewhere.
    private func pruneLocked() throws {
        let stmt = try prepare("""
            DELETE FROM mobile_local_clipboard
            WHERE id NOT IN (
                SELECT id FROM mobile_local_clipboard
                ORDER BY detected_ms DESC,id DESC LIMIT ?
            )
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(Self.maximumEntries))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Error.write }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw Error.database
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Error.database
        }
    }

    private func bind(_ text: String, in stmt: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(
            stmt, index, text, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }

    private func value(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let size = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: size),
                      as: UTF8.self)
    }
}
