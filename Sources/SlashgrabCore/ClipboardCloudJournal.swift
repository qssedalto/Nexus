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
                CREATE TABLE IF NOT EXISTS cloud_image_assets (
                    record_id TEXT PRIMARY KEY,
                    pasteboard_type TEXT NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS cloud_file_assets (
                    record_id TEXT PRIMARY KEY,
                    file_name TEXT NOT NULL,
                    payload BLOB NOT NULL
                )
                """)
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
            // Local deletion and metadata-only replacement must not retain
            // a previously downloaded image body in the CloudKit cache.
            if record.isDeleted || !Self.containsImageReference(record) {
                try removeImageLocked(id: record.id)
            }
            if record.isDeleted || !Self.containsFileReference(record) {
                try removeFileLocked(id: record.id)
            }
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
        changeToken: Data? = nil,
        imageAssets: [String: ClipboardCloudImageAsset] = [:],
        fileAssets: [String: ClipboardCloudFileAsset] = [:]
    ) throws -> Int {
        guard changes.count <= 200 else { throw ClipboardCloudModelError.oversizedBatch }
        // Coalesce retry/duplicate versions within this page before writing.
        // This makes the result and changed-key count independent of page order.
        let uniqueChanges = try ClipboardCloudMerge.merged(
            existing: [], incoming: changes
        )
        guard imageAssets.count <= 200, fileAssets.count <= 200 else {
            throw JournalError.recordTooLarge
        }
        // Validate every provided binary asset before opening a transaction.
        // Rejected bytes must NEVER be paired with an advanced change token.
        for (id, asset) in imageAssets {
            guard let record = uniqueChanges.first(where: { $0.id == id }),
                  case .operation(let content)? = record.payload,
                  let reference = content.image,
                  asset.matches(reference) else {
                throw JournalError.recordTooLarge
            }
        }
        for (id, asset) in fileAssets {
            guard let record = uniqueChanges.first(where: { $0.id == id }),
                  case .operation(let content)? = record.payload,
                  let reference = content.file,
                  asset.matches(reference) else {
                throw JournalError.recordTooLarge
            }
        }
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
            for incoming in uniqueChanges {
                if let existing = try recordLocked(id: incoming.id) {
                    let winner = try ClipboardCloudMerge.winner(existing, incoming)
                    if winner == existing { continue }
                }
                if case .operation(let content)? = incoming.payload,
                   let image = content.image {
                    guard let asset = imageAssets[incoming.id],
                          asset.matches(image) else {
                        throw JournalError.recordTooLarge
                    }
                    try storeImageLocked(asset, id: incoming.id)
                } else {
                    try removeImageLocked(id: incoming.id)
                }
                if case .operation(let content)? = incoming.payload,
                   let file = content.file {
                    guard let asset = fileAssets[incoming.id],
                          asset.matches(file) else {
                        throw JournalError.recordTooLarge
                    }
                    try storeFileLocked(asset, id: incoming.id)
                } else {
                    try removeFileLocked(id: incoming.id)
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

    private static func containsImageReference(_ record: ClipboardCloudRecord) -> Bool {
        guard case .operation(let content)? = record.payload else { return false }
        return content.image != nil
    }

    private static func containsFileReference(_ record: ClipboardCloudRecord) -> Bool {
        guard case .operation(let content)? = record.payload else { return false }
        return content.file != nil
    }

    private func removeFileLocked(id: String) throws {
        let stmt = try prepare("DELETE FROM cloud_file_assets WHERE record_id=?")
        defer { sqlite3_finalize(stmt) }
        bind(id, to: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw JournalError.write }
    }

    private func storeFileLocked(_ asset: ClipboardCloudFileAsset, id: String) throws {
        let stmt = try prepare("""
            INSERT INTO cloud_file_assets(record_id,file_name,payload)
            VALUES(?,?,?)
            ON CONFLICT(record_id) DO UPDATE SET
                file_name=excluded.file_name, payload=excluded.payload
            """)
        defer { sqlite3_finalize(stmt) }
        bind(id, to: 1, in: stmt)
        bind(asset.reference.fileName, to: 2, in: stmt)
        bind(asset.bytes, to: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw JournalError.write }
    }

    /// Verified offline CloudKit asset; call only after current download or
    /// user-requested export consent. Does not touch the source filesystem.
    public func cachedFile(recordID: String) throws -> ClipboardCloudFileAsset? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT file_name,payload FROM cloud_file_assets WHERE record_id=?"
        )
        defer { sqlite3_finalize(stmt) }
        bind(recordID, to: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let filenamePointer = sqlite3_column_text(stmt, 0) else {
            throw JournalError.read
        }
        let fileName = String(cString: filenamePointer)
        let size = Int(sqlite3_column_bytes(stmt, 1))
        guard size > 0, size <= ClipboardCloudFileReference.maximumBytes,
              let pointer = sqlite3_column_blob(stmt, 1),
              let asset = ClipboardCloudFileAsset(
                bytes: Data(bytes: pointer, count: size), fileName: fileName
              ),
              let record = try recordLocked(id: recordID),
              case .operation(let content)? = record.payload,
              let reference = content.file,
              asset.matches(reference) else { throw JournalError.read }
        return asset
    }

    private func removeImageLocked(id: String) throws {
        let stmt = try prepare("DELETE FROM cloud_image_assets WHERE record_id=?")
        defer { sqlite3_finalize(stmt) }
        bind(id, to: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw JournalError.write }
    }

    private func storeImageLocked(_ image: ClipboardCloudImageAsset, id: String) throws {
        let stmt = try prepare("""
            INSERT INTO cloud_image_assets(record_id,pasteboard_type,payload)
            VALUES(?,?,?)
            ON CONFLICT(record_id) DO UPDATE SET
                pasteboard_type=excluded.pasteboard_type,
                payload=excluded.payload
            """)
        defer { sqlite3_finalize(stmt) }
        bind(id, to: 1, in: stmt)
        bind(image.reference.pasteboardType, to: 2, in: stmt)
        bind(image.bytes, to: 3, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw JournalError.write }
    }

    /// Load a verified, previously downloaded CloudKit image body. There is
    /// no network or iOS pasteboard access in this method.
    public func cachedImage(recordID: String) throws -> ClipboardCloudImageAsset? {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT pasteboard_type,payload FROM cloud_image_assets WHERE record_id=?"
        )
        defer { sqlite3_finalize(stmt) }
        bind(recordID, to: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let typePointer = sqlite3_column_text(stmt, 0) else {
            throw JournalError.read
        }
        let type = String(cString: typePointer)
        let count = Int(sqlite3_column_bytes(stmt, 1))
        guard count > 0, count <= ClipboardCloudImageReference.maximumBytes,
              let pointer = sqlite3_column_blob(stmt, 1),
              let asset = ClipboardCloudImageAsset(
                bytes: Data(bytes: pointer, count: count),
                pasteboardType: type
              ),
              let current = try recordLocked(id: recordID),
              case .operation(let content)? = current.payload,
              let metadata = content.image,
              asset.matches(metadata) else { throw JournalError.read }
        return asset
    }

    public func record(id: String) throws -> ClipboardCloudRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try recordLocked(id: id)
    }

    /// Recent cached cloud entries for an explicit, read-only UI preview.
    /// This method never queries CloudKit or reads raw image payload tables.
    public func cachedRecords(limit: Int = 100) throws -> [ClipboardCloudRecord] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare("""
            SELECT document FROM cloud_records
            ORDER BY counter DESC, record_id DESC LIMIT ?
            """)
        defer { sqlite3_finalize(stmt) }
        bind(Int64(max(1, min(200, limit))), to: 1, in: stmt)
        var rows: [ClipboardCloudRecord] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw JournalError.read }
            rows.append(try decodeLocked(stmt, column: 0))
        }
        return rows
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

    /// Explicitly discard this device's CloudKit cache, pending outbox and
    /// server cursors. Does not affect the original local clipboard history,
    /// and never contacts iCloud. Do NOT call merely because sync is disabled.
    /// Keep the two table deletions in one transaction to avoid a stale token
    /// surviving without its corresponding cached records after a crash.
    public func discardAllLocalCloudData() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM cloud_records")
            try execute("DELETE FROM cloud_change_tokens")
            try execute("DELETE FROM cloud_image_assets")
            try execute("DELETE FROM cloud_file_assets")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Explicit recovery for an expired or invalid server change token.
    /// This never erases cached content or staged local mutations. The next
    /// download starts from the beginning and deterministic merges dedupe it.
    public func resetChangeToken(forZone zoneID: String) throws {
        guard !zoneID.isEmpty else { throw JournalError.invalidToken }
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(
            "DELETE FROM cloud_change_tokens WHERE zone_id=?"
        )
        defer { sqlite3_finalize(stmt) }
        bind(zoneID, to: 1, in: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw JournalError.write }
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
