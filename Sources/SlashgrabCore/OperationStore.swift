import Foundation
import SQLite3

public struct RecordedItem: Sendable, Equatable {
    public let name: String
    public let source: String?
    public let fileExtension: String?
    public let kind: String
    public let size: Int64?

    public init(url: URL) {
        name = url.lastPathComponent
        source = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey])
        let directory = values?.isDirectory == true && values?.isPackage != true
        if values?.isSymbolicLink == true { kind = "symlink" }
        else if values?.isPackage == true { kind = "package" }
        else { kind = directory ? "folder" : Self.kind(for: fileExtension) }
        size = directory || values?.isPackage == true ? nil : values?.fileSize.map(Int64.init)
    }

    private static func kind(for ext: String?) -> String {
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "svg"].contains(ext ?? "") { return "image" }
        if ["mp4", "mov", "mkv", "avi"].contains(ext ?? "") { return "video" }
        if ["zip", "7z", "rar", "tar", "gz"].contains(ext ?? "") { return "archive" }
        if ["pdf", "doc", "docx", "xls", "xlsx", "txt", "py"].contains(ext ?? "") { return "document" }
        return "file"
    }
}

public struct RecordedOperation: Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let eventTimeMS: Int64?
    public let detectedTimeMS: Int64
    public let completedTimeMS: Int64?
    public let sourceApplication: String?
    public let detectionMethod: String
    public let status: String
    public let target: String?
    public let durationMS: Int64?
    public let clipboardText: String?
    public let items: [RecordedItem]
}

public final class OperationStore: @unchecked Sendable {
    private let database: OpaquePointer
    private let lock = NSLock()

    public static func shared(bundle: Bundle = .main) -> OperationStore? {
        guard let group = bundle.object(forInfoDictionaryKey: SharedSettings.appGroupIdentifierInfoKey) as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return try? OperationStore(url: container.appendingPathComponent("NexusOperations.sqlite"))
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else { throw StoreError.open }
        database = connection
        sqlite3_busy_timeout(database, 3000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, type TEXT NOT NULL, event_time_ms INTEGER, detected_time_ms INTEGER NOT NULL, completed_time_ms INTEGER, source_application TEXT, detection_method TEXT NOT NULL, status TEXT NOT NULL)")
            let versionStatement = try prepare("PRAGMA user_version")
            let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
            sqlite3_finalize(versionStatement)
            if version < 2 {
                // Some local preview builds already added individual columns
                // without bumping user_version. Never destroy their history.
                let columns = try operationColumnNames()
                try execute("BEGIN IMMEDIATE")
                do {
                    if !columns.contains("target") {
                        try execute("ALTER TABLE operations ADD COLUMN target TEXT")
                    }
                    if !columns.contains("duration_ms") {
                        try execute("ALTER TABLE operations ADD COLUMN duration_ms INTEGER")
                    }
                    if !columns.contains("clipboard_text") {
                        try execute("ALTER TABLE operations ADD COLUMN clipboard_text TEXT")
                    }
                    try execute("PRAGMA user_version=2")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            try execute("CREATE INDEX IF NOT EXISTS operations_time ON operations(COALESCE(event_time_ms, detected_time_ms))")
            try execute("CREATE TABLE IF NOT EXISTS operation_items (operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE, position INTEGER NOT NULL, name TEXT NOT NULL, source TEXT, extension TEXT, kind TEXT NOT NULL, size INTEGER, PRIMARY KEY(operation_id, position))")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS operation_sync_state (operation_id TEXT PRIMARY KEY REFERENCES operations(id) ON DELETE CASCADE, synced_at_ms INTEGER NOT NULL)")
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func record(type: String, urls: [URL], sourceApplication: String?, detectionMethod: String, eventTimeMS: Int64? = nil, detectedTimeMS: Int64? = nil, completedTimeMS: Int64? = nil, target: String? = nil, clipboardText: String? = nil) throws {
        // Text-only clipboard changes have no file URL; keep them as one
        // operation with a text item rather than silently dropping them.
        guard !urls.isEmpty || (type == "text_copy" && clipboardText?.isEmpty == false) || type == "image_copy" else { return }
        let detected = detectedTimeMS ?? Int64(Date().timeIntervalSince1970 * 1000)
        let operationID = UUID().uuidString
        var items = urls.map(RecordedItem.init(url:))
        if urls.isEmpty, type == "text_copy", let clipboardText {
            items.append(RecordedItem(name: "Text", source: nil, fileExtension: nil, kind: "text", size: Int64(clipboardText.utf8.count)))
        } else if urls.isEmpty, type == "image_copy" {
            // Raw clipboard image data has no reliable file name or source.
            // Persist an observation only; never inspect pixels or persist bytes.
            items.append(RecordedItem(name: "Clipboard image", source: nil, fileExtension: nil, kind: "image", size: nil))
        }
        // A clipboard reference is not a completed file transfer. Its
        // completion/duration must remain NULL unless actually confirmed.
        let status = completedTimeMS == nil ? "clipboard_detected" : "clipboard_written"
        let duration: Int64? = {
            guard let eventTimeMS, let completedTimeMS else { return nil }
            return max(0, completedTimeMS - eventTimeMS)
        }()
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let operation = try prepare("INSERT INTO operations (id, type, event_time_ms, detected_time_ms, completed_time_ms, source_application, detection_method, status, target, duration_ms, clipboard_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(operation) }
            bind(operationID, to: 1, in: operation)
            bind(type, to: 2, in: operation)
            bind(eventTimeMS, to: 3, in: operation)
            bind(detected, to: 4, in: operation)
            bind(completedTimeMS, to: 5, in: operation)
            bind(sourceApplication, to: 6, in: operation)
            bind(detectionMethod, to: 7, in: operation)
            bind(status, to: 8, in: operation)
            bind(target, to: 9, in: operation)
            bind(duration, to: 10, in: operation)
            bind(clipboardText, to: 11, in: operation)
            guard sqlite3_step(operation) == SQLITE_DONE else { throw StoreError.write }
            let item = try prepare("INSERT INTO operation_items VALUES (?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(item) }
            for (index, value) in items.enumerated() {
                sqlite3_reset(item)
                sqlite3_clear_bindings(item)
                bind(operationID, to: 1, in: item)
                bind(Int64(index), to: 2, in: item)
                bind(value.name, to: 3, in: item)
                bind(value.source, to: 4, in: item)
                bind(value.fileExtension, to: 5, in: item)
                bind(value.kind, to: 6, in: item)
                bind(value.size, to: 7, in: item)
                guard sqlite3_step(item) == SQLITE_DONE else { throw StoreError.write }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func query(from startMS: Int64, to endMS: Int64) throws -> [RecordedOperation] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("SELECT id, type, event_time_ms, detected_time_ms, completed_time_ms, source_application, detection_method, status, target, duration_ms, clipboard_text FROM operations WHERE COALESCE(event_time_ms, detected_time_ms) >= ? AND COALESCE(event_time_ms, detected_time_ms) < ? ORDER BY COALESCE(event_time_ms, detected_time_ms) DESC, id DESC")
        defer { sqlite3_finalize(statement) }
        bind(startMS, to: 1, in: statement)
        bind(endMS, to: 2, in: statement)
        var results: [RecordedOperation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try readOperation(from: statement))
        }
        return results
    }

    // Local-only, bounded queue: the same operation UUID is retried until a
    // server response explicitly acknowledges it. Nothing is deleted on error.
    public func pendingSync(limit: Int = 25) throws -> [RecordedOperation] {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            SELECT id, type, event_time_ms, detected_time_ms, completed_time_ms,
                   source_application, detection_method, status, target, duration_ms, clipboard_text
            FROM operations
            WHERE id NOT IN (SELECT operation_id FROM operation_sync_state)
              AND id NOT LIKE 'remote:%'
            ORDER BY detected_time_ms, id
            LIMIT ?
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(Int64(max(1, min(50, limit))), to: 1, in: stmt)
        var records: [RecordedOperation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(try readOperation(from: stmt))
        }
        return records
    }

    public func markSynced(operationIDs ids: [String]) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let stmt = try prepare("""
                INSERT INTO operation_sync_state(operation_id, synced_at_ms)
                VALUES(?, ?)
                ON CONFLICT(operation_id) DO UPDATE SET synced_at_ms=excluded.synced_at_ms
                """)
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for id in Set(ids) {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(id, to: 1, in: stmt)
                bind(now, to: 2, in: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.write }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Remote device records are materialized under stable namespaced IDs and
    /// excluded from the local outbound queue. Replaying the same page does
    /// not insert duplicates or add event counts.
    public func importRemote(_ remote: [RemoteOperationRecord]) throws -> Int {
        guard !remote.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let opStmt = try prepare("""
                INSERT OR IGNORE INTO operations
                (id,type,event_time_ms,detected_time_ms,completed_time_ms,source_application,
                detection_method,status,target,duration_ms,clipboard_text)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(opStmt) }
            let itemStmt = try prepare("""
                INSERT OR IGNORE INTO operation_items
                (operation_id,position,name,source,extension,kind,size)
                VALUES(?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(itemStmt) }
            var inserted = 0
            for entry in remote {
                let op = entry.operation
                guard !entry.deviceID.isEmpty, entry.deviceID.count <= 80,
                      UUID(uuidString: op.id) != nil,
                      op.detectedTimeMS >= 0, op.items.count <= 100 else { continue }
                let localID = "remote:\(entry.deviceID):\(op.id)"
                // Skip imports of an unchanged local source operation.
                let exists = try prepare("SELECT 1 FROM operations WHERE id IN (?, ?) LIMIT 1")
                bind(op.id, to: 1, in: exists)
                bind(localID, to: 2, in: exists)
                let alreadyExists = sqlite3_step(exists) == SQLITE_ROW
                sqlite3_finalize(exists)
                if alreadyExists { continue }

                sqlite3_reset(opStmt)
                sqlite3_clear_bindings(opStmt)
                bind(localID, to: 1, in: opStmt)
                bind(op.type, to: 2, in: opStmt)
                bind(op.eventTimeMS, to: 3, in: opStmt)
                bind(op.detectedTimeMS, to: 4, in: opStmt)
                bind(op.completedTimeMS, to: 5, in: opStmt)
                bind(op.sourceApplication, to: 6, in: opStmt)
                bind("remote_restore", to: 7, in: opStmt)
                bind(op.status, to: 8, in: opStmt)
                bind(op.target, to: 9, in: opStmt)
                bind(op.durationMS, to: 10, in: opStmt)
                bind(op.clipboardText, to: 11, in: opStmt)
                guard sqlite3_step(opStmt) == SQLITE_DONE else { throw StoreError.write }
                for item in op.items {
                    guard item.position >= 0, item.position < 100 else { throw StoreError.write }
                    sqlite3_reset(itemStmt)
                    sqlite3_clear_bindings(itemStmt)
                    bind(localID, to: 1, in: itemStmt)
                    bind(Int64(item.position), to: 2, in: itemStmt)
                    bind(item.name, to: 3, in: itemStmt)
                    bind(item.source, to: 4, in: itemStmt)
                    bind(item.fileExtension, to: 5, in: itemStmt)
                    bind(item.kind, to: 6, in: itemStmt)
                    bind(item.size, to: 7, in: itemStmt)
                    guard sqlite3_step(itemStmt) == SQLITE_DONE else { throw StoreError.write }
                }
                inserted += 1
            }
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func readOperation(from statement: OpaquePointer) throws -> RecordedOperation {
        let id = string(statement, 0) ?? ""
        let itemStmt = try prepare("SELECT name, source, extension, kind, size FROM operation_items WHERE operation_id = ? ORDER BY position")
        defer { sqlite3_finalize(itemStmt) }
        bind(id, to: 1, in: itemStmt)
        var items: [RecordedItem] = []
        while sqlite3_step(itemStmt) == SQLITE_ROW {
            items.append(RecordedItem(name: string(itemStmt, 0) ?? "",
                                      source: string(itemStmt, 1),
                                      fileExtension: string(itemStmt, 2),
                                      kind: string(itemStmt, 3) ?? "file",
                                      size: integer(itemStmt, 4)))
        }
        return RecordedOperation(
            id: id, type: string(statement, 1) ?? "",
            eventTimeMS: integer(statement, 2),
            detectedTimeMS: sqlite3_column_int64(statement, 3),
            completedTimeMS: integer(statement, 4),
            sourceApplication: string(statement, 5),
            detectionMethod: string(statement, 6) ?? "",
            status: string(statement, 7) ?? "",
            target: string(statement, 8),
            durationMS: integer(statement, 9),
            clipboardText: string(statement, 10),
            items: items)
    }

    private func operationColumnNames() throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(operations)")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = string(statement, 1) { names.insert(name) }
        }
        return names
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.write }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreError.write }
        return statement
    }
    private func bind(_ value: String?, to column: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_text(statement, column, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        else { sqlite3_bind_null(statement, column) }
    }
    private func bind(_ value: Int64?, to column: Int32, in statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, column, value) }
        else { sqlite3_bind_null(statement, column) }
    }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    private func integer(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }
    public enum StoreError: Error { case open, write }
}

private extension RecordedItem {
    init(name: String, source: String?, fileExtension: String?, kind: String, size: Int64?) {
        self.name = name
        self.source = source
        self.fileExtension = fileExtension
        self.kind = kind
        self.size = size
    }
}
