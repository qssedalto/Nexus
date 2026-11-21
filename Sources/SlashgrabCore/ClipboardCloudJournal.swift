import Foundation
import SQLite3

/// Durable, offline-first outbox and remote record cache for a future private
/// CloudKit zone. Does NOT initialize CloudKit, sign in or transmit anything.
/// Stored separately from NexusOperations.sqlite to keep existing history safe.
public final class ClipboardCloudJournal: @unchecked Sendable {
    public enum JournalError: Error, Sendable {
        case open, read, write, invalidToken, recordTooLarge
    }

    private let database: OpaquePointer
    private let lock = NSLock()
    private static let maximumRecordBytes = 256 * 1024

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw JournalError.open
        }
        database = connection
        sqlite3_busy_timeout(database, 3_000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("""
                CREATE TABLE IF NOT EXISTS cloud_records (
                    record_id TEXT PRIMARY KEY,
                    document BLOB NOT NULL,
                    mutation_id TEXT NOT NULL,
                    counter INTEGER NOT NULL,
                    dirty INTEGER NOT NULL CHECK (dirty IN (0,1))
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS cloud_pending ON cloud_records(dirty,counter,record_id)")
            try execute("""
                CREATE TABLE IF NOT EXISTS cloud_change_tokens (
                    zone_id TEXT PRIMARY KEY, token BLOB NOT NULL
                )
                """)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Stage a locally authorized edit, including a payload-free tombstone.
    /// Caller MUST have checked user consent; this API never watches clipboard.
    /// A stale revision cannot overwrite newer remote or local data.
    @discardableResult
    public func stageLocal(_ record: ClipboardCloudRecord) throws -> Bool {
        _ = try record.validated()
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            if let existing = try recordLocked(id: record.id) {
                let winner = try ClipboardCloudMerge.winner(existing, record)
                if winner == existing {
                    try execute("COMMIT")
                    return false
                }
            }
            try storeLocked(record, dirty: true)
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Merge a bounded CloudKit download page and its change token atomically.
    /// A bad record or disk error does not advance the persisted server token.
    /// This is vital for crash-safe replay after a network or app failure.
    @discardableResult
    public func applyRemote(
        _ changes: [ClipboardCloudRecord],
        zoneID: String? = nil,
        changeToken: Data? = nil
    ) throws -> Int {
        guard changes.count <= 200 else { throw ClipboardCloudModelError.oversizedBatch }
        for change in changes { _ = try change.validated() }
        if changeToken != nil {
            guard let zoneID, !zoneID.isEmpty, zoneID.utf8.count <= 180,
                  let changeToken, !changeToken.isEmpty,
                  changeToken.count <= 64 * 1024 else { throw JournalError.invalidToken }
        }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var changed = 0
            for incoming in changes {
                if let existing = try recordLocked(id: incoming.id) {
                    let winner = try ClipboardCloudMerge.winner(existing, incoming)
                    if winner == existing { continue }
                }
                try storeLocked(incoming, dirty: false)
                changed += 1
            }
            if let zoneID, let changeToken {
                let statement = try prepare("""
                    INSERT INTO cloud_change_tokens(zone_id,token) VALUES(?,?)
                    ON CONFLICT(zone_id) DO UPDATE SET token=excluded.token
                    """)
                defer { sqlite3_finalize(statement) }
                bind(zoneID, to: 1, in: statement)
                bind(changeToken, to: 2, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw JournalError.write
                }
            }
            try execute("COMMIT")
            return changed
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func record(id: String) throws -> ClipboardCloudRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try recordLocked(id: id)
    }

    /// Bounded batch for future CKModifyRecordsOperation. Retried local
    /// updates use their original mutationID until the server acknowledges.
    public func pending(limit: Int = 100) throws -> [ClipboardCloudRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            SELECT document FROM cloud_records
            WHERE dirty=1 ORDER BY counter,record_id LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(Int64(max(1, min(200, limit))), to: 1, in: statement)
        var result: [ClipboardCloudRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw JournalError.read }
            result.append(try decodeLocked(statement, column: 0))
        }
        return result
    }

    public func pendingCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT COUNT(*) FROM cloud_records WHERE dirty=1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw JournalError.read }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Only acknowledge the exact immutable mutation that was uploaded.
    /// If the user edited/deleted the entry while the request was in flight,
    /// its newer mutation remains dirty and will be retried later.
    @discardableResult
    public func acknowledgeUploaded(id: String, mutationID: String) throws -> Bool {
        guard UUID(uuidString: mutationID) != nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            UPDATE cloud_records SET dirty=0
            WHERE record_id=? AND mutation_id=? AND dirty=1
            """)
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        bind(mutationID, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JournalError.write }
        return sqlite3_changes(database) > 0
    }

    /// Opaque CKServerChangeToken data, never user-facing or loggable.
    public func token(forZone zoneID: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(
            "SELECT token FROM cloud_change_tokens WHERE zone_id=?"
        )
        defer { sqlite3_finalize(statement) }
        bind(zoneID, to: 1, in: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw JournalError.read }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0, length <= 64 * 1024,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw JournalError.read
        }
        return Data(bytes: bytes, count: length)
    }

    private func recordLocked(id: String) throws -> ClipboardCloudRecord? {
        let statement = try prepare("SELECT document FROM cloud_records WHERE record_id=?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw JournalError.read }
        return try decodeLocked(statement, column: 0)
    }

    private func decodeLocked(
        _ statement: OpaquePointer, column: Int32
    ) throws -> ClipboardCloudRecord {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, length <= Self.maximumRecordBytes,
              let bytes = sqlite3_column_blob(statement, column) else {
            throw JournalError.read
        }
        let data = Data(bytes: bytes, count: length)
        return try JSONDecoder().decode(ClipboardCloudRecord.self, from: data).validated()
    }

    private func storeLocked(
        _ record: ClipboardCloudRecord, dirty: Bool
    ) throws {
        let data = try JSONEncoder().encode(record.validated())
        guard data.count <= Self.maximumRecordBytes else { throw JournalError.recordTooLarge }
        let statement = try prepare("""
            INSERT INTO cloud_records(record_id,document,mutation_id,counter,dirty)
            VALUES(?,?,?,?,?)
            ON CONFLICT(record_id) DO UPDATE SET
                document=excluded.document, mutation_id=excluded.mutation_id,
                counter=excluded.counter,dirty=excluded.dirty
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.id, to: 1, in: statement)
        bind(data, to: 2, in: statement)
        bind(record.mutationID, to: 3, in: statement)
        bind(record.revision.counter, to: 4, in: statement)
        bind(Int64(dirty ? 1 : 0), to: 5, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JournalError.write }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw JournalError.read
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw JournalError.write
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(
            statement, index, value, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ data: Data, to index: Int32, in statement: OpaquePointer) {
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(
                statement, index, bytes.baseAddress, Int32(data.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }
}
