import Foundation
import SQLite3

public struct InputCount: Sendable, Identifiable {
    public let name: String
    public let count: Int64
    public var id: String { name }
}

public struct InputCategoryCount: Sendable, Identifiable, Equatable {
    public let category: String
    public let name: String
    public let count: Int64
    public let lastTimeMS: Int64
    public var id: String { category + ":" + name }
}

public struct InputSourceCount: Sendable, Identifiable, Equatable {
    public let source: String
    public let category: String
    public let count: Int64
    public let lastTimeMS: Int64
    public var id: String { source + ":" + category }
}

public struct InputTrendBucket: Sendable, Identifiable, Equatable {
    /// UTC start time in epoch milliseconds. The UI can display local time.
    public let startMS: Int64
    public let category: String
    public let count: Int64
    public var id: String { "\(startMS):\(category)" }
}

public enum InputTrendResolution: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month
    public var id: String { rawValue }
}

public struct InputStatisticsOverview: Sendable, Equatable {
    public let keyboard: Int64
    public let mouse: Int64
    public let specialKeys: Int64
    public let shortcuts: Int64
    public let scrolls: Int64
    public let firstEventMS: Int64?

    public init(keyboard: Int64, mouse: Int64, specialKeys: Int64,
                shortcuts: Int64, scrolls: Int64, firstEventMS: Int64?) {
        self.keyboard = keyboard
        self.mouse = mouse
        self.specialKeys = specialKeys
        self.shortcuts = shortcuts
        self.scrolls = scrolls
        self.firstEventMS = firstEventMS
    }
}

public struct ClassifiedInputEvent: Sendable, Hashable {
    public let timeMS: Int64
    public let category: String
    public let name: String
    public let source: String
    public let isRepeat: Bool

    public init(timeMS: Int64, category: String, name: String, source: String, isRepeat: Bool = false) {
        self.timeMS = timeMS
        self.category = category
        self.name = name
        self.source = source
        self.isRepeat = isRepeat
    }
}

public struct SyncInputEvent: Codable, Sendable, Identifiable {
    public let id: Int64
    public let timeMS: Int64
    public let category: String
    public let name: String
    public let count: Int64

    enum CodingKeys: String, CodingKey {
        case id, category, name, count
        case timeMS = "time_ms"
    }
}

public struct RemoteInputEvent: Decodable, Sendable {
    public let deviceID: String
    public let id: Int64
    public let timeMS: Int64
    public let category: String
    public let name: String
    public let count: Int64

    enum CodingKeys: String, CodingKey {
        case id, category, name, count
        case deviceID = "device_id", timeMS = "time_ms"
    }
}

public final class InputStatisticsStore: @unchecked Sendable {
    private let database: OpaquePointer
    private let databaseURL: URL
    private let queue = DispatchQueue(label: "com.nexus.input-statistics", qos: .utility)
    private var pending: [ClassifiedInputEvent] = []
    private var timer: DispatchSourceTimer?

    public static func shared(bundle: Bundle = .main) -> InputStatisticsStore? {
        guard let group = bundle.object(forInfoDictionaryKey: SharedSettings.appGroupIdentifierInfoKey) as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return try? InputStatisticsStore(url: container.appendingPathComponent("NexusStatistics.sqlite"))
    }

    public init(url: URL) throws {
        databaseURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else { throw InputStoreError.open }
        database = connection
        sqlite3_busy_timeout(database, 3000)
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS input_events (id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, category TEXT NOT NULL, name TEXT NOT NULL, source TEXT NOT NULL, is_repeat INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS input_events_time ON input_events(time_ms); CREATE INDEX IF NOT EXISTS input_events_name_time ON input_events(name, time_ms)", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw InputStoreError.write
        }
        // Earlier preview versions may have added columns without updating
        // PRAGMA user_version. Inspect the actual schema and add only missing
        // fields rather than losing years of accumulated statistics.
        var columnStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(input_events)", -1,
                                 &columnStatement, nil) == SQLITE_OK,
              let columnStatement else {
            sqlite3_close(database)
            throw InputStoreError.open
        }
        var columnNames = Set<String>()
        while sqlite3_step(columnStatement) == SQLITE_ROW {
            if let text = sqlite3_column_text(columnStatement, 1) {
                columnNames.insert(String(cString: text))
            }
        }
        sqlite3_finalize(columnStatement)
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw InputStoreError.write
        }
        do {
            let required = [
                ("count", "INTEGER NOT NULL DEFAULT 1"),
                ("synced_at_ms", "INTEGER"),
                ("remote_device_id", "TEXT"),
                ("remote_event_id", "INTEGER")
            ]
            for (field, type) in required where !columnNames.contains(field) {
                guard sqlite3_exec(database,
                      "ALTER TABLE input_events ADD COLUMN \(field) \(type)",
                      nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
            }
            let indexes = """
                CREATE INDEX IF NOT EXISTS input_events_pending ON input_events(synced_at_ms,id);
                CREATE UNIQUE INDEX IF NOT EXISTS input_events_remote ON input_events(remote_device_id,remote_event_id);
                CREATE INDEX IF NOT EXISTS input_events_source_range ON input_events(source, time_ms);
                PRAGMA user_version=4;
                """
            guard sqlite3_exec(database, indexes, nil, nil, nil) == SQLITE_OK,
                  sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw InputStoreError.write
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
            throw error
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in try? self?.flushOnQueue() }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        queue.sync {
            try? flushOnQueue()
            sqlite3_close(database)
        }
    }

    public func enqueue(_ event: ClassifiedInputEvent) {
        queue.async { [self] in
            pending.append(event)
            if pending.count >= 256 { try? flushOnQueue() }
        }
    }

    public func counts(from startMS: Int64, to endMS: Int64) throws -> [InputCount] {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT name, SUM(count) FROM input_events WHERE time_ms >= ? AND time_ms < ? GROUP BY name ORDER BY SUM(count) DESC", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            var result: [InputCount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 0) else { continue }
                result.append(InputCount(name: String(cString: rawName), count: sqlite3_column_int64(statement, 1)))
            }
            return result
        }
    }

    /// Real device model/location metadata is recorded only if IOHID exposes
    /// it. Quartz and AppKit source names remain channel labels, not devices.
    public func sourceCounts(from startMS: Int64, to endMS: Int64) throws -> [InputSourceCount] {
        try queue.sync {
            try flushOnQueue()
            var stmt: OpaquePointer?
            let sql = """
                SELECT source, category, SUM(count), MAX(time_ms)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                GROUP BY source, category
                ORDER BY SUM(count) DESC, source, category
                """
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { throw InputStoreError.read }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, startMS)
            sqlite3_bind_int64(stmt, 2, endMS)
            var result: [InputSourceCount] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let source = sqlite3_column_text(stmt, 0),
                      let category = sqlite3_column_text(stmt, 1) else { continue }
                result.append(InputSourceCount(
                    source: String(cString: source),
                    category: String(cString: category),
                    count: sqlite3_column_int64(stmt, 2),
                    lastTimeMS: sqlite3_column_int64(stmt, 3)
                ))
            }
            return result
        }
    }

    /// Queries are half-open UTC [from,to), preserving millisecond bounds.
    /// No inferred events or interpolation is used in summaries/trends.
    public func categoryCounts(from startMS: Int64, to endMS: Int64,
                               source: String? = nil) throws -> [InputCategoryCount] {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            let sql = """
                SELECT category, name, SUM(count), MAX(time_ms)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                  AND (? IS NULL OR source = ?)
                GROUP BY category, name
                ORDER BY SUM(count) DESC, category, name
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            if let source {
                bind(source, to: 3, in: statement)
                bind(source, to: 4, in: statement)
            } else {
                sqlite3_bind_null(statement, 3)
                sqlite3_bind_null(statement, 4)
            }
            var records: [InputCategoryCount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let category = sqlite3_column_text(statement, 0),
                      let name = sqlite3_column_text(statement, 1) else { continue }
                records.append(InputCategoryCount(
                    category: String(cString: category), name: String(cString: name),
                    count: sqlite3_column_int64(statement, 2),
                    lastTimeMS: sqlite3_column_int64(statement, 3)))
            }
            return records
        }
    }

    public func overview(from startMS: Int64, to endMS: Int64,
                         source: String? = nil) throws -> InputStatisticsOverview {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            let sql = """
                SELECT category, SUM(count)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                  AND (? IS NULL OR source = ?)
                GROUP BY category
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            if let source {
                bind(source, to: 3, in: statement)
                bind(source, to: 4, in: statement)
            } else {
                sqlite3_bind_null(statement, 3)
                sqlite3_bind_null(statement, 4)
            }
            var categories: [String: Int64] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                categories[String(cString: raw)] = sqlite3_column_int64(statement, 1)
            }
            var first: OpaquePointer?
            guard sqlite3_prepare_v2(
                    database,
                    "SELECT MIN(time_ms) FROM input_events WHERE (? IS NULL OR source = ?)",
                    -1, &first, nil
                  ) == SQLITE_OK,
                  let first else { throw InputStoreError.read }
            defer { sqlite3_finalize(first) }
            if let source {
                bind(source, to: 1, in: first)
                bind(source, to: 2, in: first)
            } else {
                sqlite3_bind_null(first, 1)
                sqlite3_bind_null(first, 2)
            }
            let firstEvent: Int64? = sqlite3_step(first) == SQLITE_ROW &&
                sqlite3_column_type(first, 0) != SQLITE_NULL
                ? sqlite3_column_int64(first, 0) : nil
            return InputStatisticsOverview(
                keyboard: (categories["keyboard"] ?? 0) +
                          (categories["ordinary"] ?? 0) +
                          (categories["modifier"] ?? 0) +
                          (categories["system"] ?? 0),
                mouse: categories["mouse"] ?? 0,
                specialKeys: (categories["keyboard"] ?? 0) +
                             (categories["modifier"] ?? 0) +
                             (categories["system"] ?? 0),
                shortcuts: categories["shortcut"] ?? 0,
                scrolls: categories["scroll"] ?? 0,
                firstEventMS: firstEvent)
        }
    }

    public func trend(from startMS: Int64, to endMS: Int64,
                      resolution: InputTrendResolution,
                      category: String? = nil,
                      name: String? = nil,
                      source: String? = nil) throws -> [InputTrendBucket] {
        guard startMS >= 0, endMS >= startMS else { return [] }
        return try queue.sync {
            try flushOnQueue()
            return try trendOnQueue(startMS: startMS, endMS: endMS,
                                    resolution: resolution, category: category,
                                    name: name, source: source)
        }
    }

    /// Called only with the private SQLite serial queue held. Keep the body
    /// separate so Swift 6 can type-check the queue closure in finite time.
    private func trendOnQueue(startMS: Int64, endMS: Int64,
                              resolution: InputTrendResolution,
                              category: String?, name: String?,
                              source: String?) throws -> [InputTrendBucket] {
            // Push the potentially massive event-range scan/grouping into
            // SQLite. Swift sees only hourly/daily UTC buckets, even when
            // many years of input events are stored.
            let periodMS: Int64 = resolution == .hour ? 3_600_000 : 86_400_000
            var statement: OpaquePointer?
            let sql = """
                SELECT (time_ms / \(periodMS)) * \(periodMS) AS bucket_ms,
                       category, SUM(count)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                  AND (? IS NULL OR category = ?)
                  AND (? IS NULL OR name = ?)
                  AND (? IS NULL OR source = ?)
                GROUP BY bucket_ms, category
                ORDER BY bucket_ms, category
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            if let category {
                bind(category, to: 3, in: statement)
                bind(category, to: 4, in: statement)
            } else {
                sqlite3_bind_null(statement, 3)
                sqlite3_bind_null(statement, 4)
            }
            if let name {
                bind(name, to: 5, in: statement)
                bind(name, to: 6, in: statement)
            } else {
                sqlite3_bind_null(statement, 5)
                sqlite3_bind_null(statement, 6)
            }
            if let source {
                bind(source, to: 7, in: statement)
                bind(source, to: 8, in: statement)
            } else {
                sqlite3_bind_null(statement, 7)
                sqlite3_bind_null(statement, 8)
            }
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var counts: [String: (Int64, String, Int64)] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventMS = sqlite3_column_int64(statement, 0)
                let raw = sqlite3_column_text(statement, 1)
                guard let raw else { continue }
                let group = String(cString: raw)
                let date = Date(timeIntervalSince1970: TimeInterval(eventMS) / 1000)
                let component: Calendar.Component
                switch resolution {
                case .hour: component = .hour
                case .day: component = .day
                case .week: component = .weekOfYear
                case .month: component = .month
                }
                guard let interval = calendar.dateInterval(of: component, for: date) else { continue }
                let bucket = Int64(interval.start.timeIntervalSince1970 * 1000)
                let key = "\(bucket):\(group)"
                let previous = counts[key]?.2 ?? 0
                counts[key] = (bucket, group, previous + sqlite3_column_int64(statement, 2))
            }
            let rows: [InputTrendBucket] = counts.values.map { item in
                InputTrendBucket(startMS: item.0, category: item.1, count: item.2)
            }
            return rows.sorted { lhs, rhs in
                if lhs.startMS == rhs.startMS { return lhs.category < rhs.category }
                return lhs.startMS < rhs.startMS
            }
    }

    public func pendingSync(limit: Int = 500) throws -> [SyncInputEvent] {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT id, time_ms, category, name, count FROM input_events WHERE synced_at_ms IS NULL ORDER BY id LIMIT ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, min(1000, limit))))
            var events: [SyncInputEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let category = sqlite3_column_text(statement, 2),
                      let name = sqlite3_column_text(statement, 3) else { continue }
                events.append(SyncInputEvent(id: sqlite3_column_int64(statement, 0), timeMS: sqlite3_column_int64(statement, 1), category: String(cString: category), name: String(cString: name), count: sqlite3_column_int64(statement, 4)))
            }
            return events
        }
    }

    public func markSynced(ids: [Int64], deviceID: String? = nil) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE input_events SET synced_at_ms = ?, remote_device_id = ?, remote_event_id = ? WHERE id = ? AND synced_at_ms IS NULL", -1, &statement, nil) == SQLITE_OK,
                  let statement else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw InputStoreError.write }
            defer { sqlite3_finalize(statement) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, now)
                if let deviceID { bind(deviceID, to: 2, in: statement); sqlite3_bind_int64(statement, 3, id) }
                sqlite3_bind_int64(statement, 4, id)
                guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw InputStoreError.write }
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
        }
    }

    public func importRemote(_ events: [RemoteInputEvent]) throws -> Int {
        try queue.sync {
            try flushOnQueue()
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO input_events(time_ms,category,name,source,is_repeat,count,synced_at_ms,remote_device_id,remote_event_id) VALUES(?,?,?,'remote_restore',0,?,?,?,?) ON CONFLICT(remote_device_id,remote_event_id) DO NOTHING", -1, &statement, nil) == SQLITE_OK,
                  let statement else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw InputStoreError.write }
            defer { sqlite3_finalize(statement) }
            var inserted = 0
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            for event in events {
                guard event.id >= 0, event.timeMS >= 0, event.count > 0,
                      event.deviceID.count <= 80, event.name.count <= 80,
                      ["ordinary", "keyboard", "modifier", "shortcut", "mouse", "scroll", "system"].contains(event.category) else {
                    sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                    throw InputStoreError.write
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, event.timeMS)
                bind(event.category, to: 2, in: statement)
                bind(event.name, to: 3, in: statement)
                sqlite3_bind_int64(statement, 4, event.count)
                sqlite3_bind_int64(statement, 5, now)
                bind(event.deviceID, to: 6, in: statement)
                sqlite3_bind_int64(statement, 7, event.id)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                    throw InputStoreError.write
                }
                inserted += Int(sqlite3_changes(database))
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
            return inserted
        }
    }

    public func delete(from startMS: Int64, to endMS: Int64) throws -> Int {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM input_events WHERE time_ms >= ? AND time_ms < ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.write }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw InputStoreError.write }
            return Int(sqlite3_changes(database))
        }
    }

    public func integrityCheck() throws -> String {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let result = sqlite3_column_text(statement, 0) else { throw InputStoreError.read }
            return String(cString: result)
        }
    }

    /// Safely merge a user-selected iCloud SQLite snapshot. This is never a
    /// destructive database replacement: existing local rows remain untouched.
    /// Imported rows use a stable namespaced source ID, making retries and
    /// re-downloading the same backup idempotent.
    public func restoreBackup(from source: URL, deviceID: String) throws -> Int {
        guard source.standardizedFileURL != databaseURL.standardizedFileURL,
              !deviceID.isEmpty, deviceID.count <= 80 else { throw InputStoreError.write }
        // An iCloud file can be backed by File Provider, or by a SQLite
        // online-backup snapshot whose header retains WAL mode without WAL
        // sidecars. First copy it into a private writable staging directory,
        // then open the *static snapshot* as immutable/read-only. This avoids
        // SQLite trying to open nonexistent WAL/SHM files in the provider's
        // directory, and prevents a source file changing mid-import.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexusBackupRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let snapshot = staging.appendingPathComponent("snapshot.sqlite")
        try FileManager.default.copyItem(at: source, to: snapshot)
        let uri = snapshot.absoluteString + "?immutable=1"
        var sourceDB: OpaquePointer?
        guard sqlite3_open_v2(uri, &sourceDB,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let sourceDB else {
            if let sourceDB { sqlite3_close(sourceDB) }
            throw InputStoreError.open
        }
        defer { sqlite3_close(sourceDB) }

        var check: OpaquePointer?
        guard sqlite3_prepare_v2(sourceDB, "PRAGMA quick_check(1)", -1, &check, nil) == SQLITE_OK,
              let check else { throw InputStoreError.backupRead("integrity preflight: \(String(cString: sqlite3_errmsg(sourceDB)))") }
        let healthy = sqlite3_step(check) == SQLITE_ROW &&
            sqlite3_column_text(check, 0).map { String(cString: $0) } == "ok"
        sqlite3_finalize(check)
        guard healthy else { throw InputStoreError.backupRead("backup failed quick_check") }

        var cursor: OpaquePointer?
        let sql = """
            SELECT id,time_ms,category,name,source,count,
                   remote_device_id,remote_event_id
            FROM input_events ORDER BY id
            """
        guard sqlite3_prepare_v2(sourceDB, sql, -1, &cursor, nil) == SQLITE_OK,
              let cursor else { throw InputStoreError.backupRead("missing backup schema: \(String(cString: sqlite3_errmsg(sourceDB)))") }
        defer { sqlite3_finalize(cursor) }

        var rows: [BackupInputEvent] = []
        var inserted = 0
        while true {
            let step = sqlite3_step(cursor)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let category = sqlite3_column_text(cursor, 2),
                  let name = sqlite3_column_text(cursor, 3),
                  let source = sqlite3_column_text(cursor, 4) else {
                throw InputStoreError.backupRead("invalid backup cursor row or unexpected SQLite result: \(step)")
            }
            let row = BackupInputEvent(
                id: sqlite3_column_int64(cursor, 0),
                timeMS: sqlite3_column_int64(cursor, 1),
                category: String(cString: category),
                name: String(cString: name),
                source: String(cString: source),
                count: sqlite3_column_int64(cursor, 5),
                originDeviceID: sqlite3_column_text(cursor, 6).map { String(cString: $0) },
                originEventID: sqlite3_column_type(cursor, 7) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(cursor, 7)
            )
            guard row.id >= 0, row.timeMS >= 0, row.count > 0,
                  row.name.count <= 80, row.source.count <= 512,
                  (row.originDeviceID == nil) == (row.originEventID == nil),
                  (row.originDeviceID?.count ?? 0) <= 80,
                  (row.originEventID ?? 0) >= 0,
                  ["ordinary", "keyboard", "modifier", "shortcut", "mouse", "scroll", "system"].contains(row.category) else {
                throw InputStoreError.backupRead("invalid input record \(row.id) category=\(row.category)")
            }
            rows.append(row)
            if rows.count == 250 {
                inserted += try mergeBackupBatch(rows, deviceID: deviceID)
                rows.removeAll(keepingCapacity: true)
            }
        }
        if !rows.isEmpty { inserted += try mergeBackupBatch(rows, deviceID: deviceID) }
        return inserted
    }

    private struct BackupInputEvent {
        let id: Int64
        let timeMS: Int64
        let category: String
        let name: String
        let source: String
        let count: Int64
        let originDeviceID: String?
        let originEventID: Int64?
    }

    private func mergeBackupBatch(_ batch: [BackupInputEvent], deviceID: String) throws -> Int {
        try queue.sync {
            try flushOnQueue()
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw InputStoreError.write
            }
            var existing: OpaquePointer?
            var insert: OpaquePointer?
            defer {
                if let existing { sqlite3_finalize(existing) }
                if let insert { sqlite3_finalize(insert) }
            }
            do {
                let checkSQL = """
                    SELECT 1 FROM input_events
                    WHERE time_ms = ? AND category = ?
                      AND name = ? AND source = ? AND count = ?
                      AND remote_device_id IS NULL
                    LIMIT 1
                    """
                guard sqlite3_prepare_v2(database, checkSQL, -1, &existing, nil) == SQLITE_OK,
                      let existing else { throw InputStoreError.write }
                let insertSQL = """
                    INSERT INTO input_events
                    (time_ms,category,name,source,is_repeat,count,synced_at_ms,
                     remote_device_id,remote_event_id)
                    VALUES(?,?,?,?,0,?,?,?,?)
                    ON CONFLICT(remote_device_id,remote_event_id) DO NOTHING
                    """
                guard sqlite3_prepare_v2(database, insertSQL, -1, &insert, nil) == SQLITE_OK,
                      let insert else { throw InputStoreError.write }
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                var inserted = 0
                for row in batch {
                    // Preserve the original source device across A -> B -> A
                    // iCloud file sync cycles. Never re-tag an imported row
                    // as originating from the intermediate backup machine.
                    let originDeviceID = row.originDeviceID ?? deviceID
                    let originEventID = row.originEventID ?? row.id
                    sqlite3_reset(existing)
                    sqlite3_clear_bindings(existing)
                    // Local database integer IDs are assigned in buffered
                    // flush order, so another Mac's identical local event may
                    // have a different ID. Compare its event fingerprint.
                    sqlite3_bind_int64(existing, 1, row.timeMS)
                    bind(row.category, to: 2, in: existing)
                    bind(row.name, to: 3, in: existing)
                    bind(row.source, to: 4, in: existing)
                    sqlite3_bind_int64(existing, 5, row.count)
                    if sqlite3_step(existing) == SQLITE_ROW { continue }

                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    sqlite3_bind_int64(insert, 1, row.timeMS)
                    bind(row.category, to: 2, in: insert)
                    bind(row.name, to: 3, in: insert)
                    bind(row.source, to: 4, in: insert)
                    sqlite3_bind_int64(insert, 5, row.count)
                    sqlite3_bind_int64(insert, 6, now)
                    bind(originDeviceID, to: 7, in: insert)
                    sqlite3_bind_int64(insert, 8, originEventID)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw InputStoreError.write
                    }
                    inserted += Int(sqlite3_changes(database))
                }
                guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw InputStoreError.write
                }
                return inserted
            } catch {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    /// SQLite's VACUUM INTO creates a consistent, independently readable
    /// single-file snapshot from a live WAL database. Unlike a raw copy or
    /// sqlite3_backup + journal conversion it never relies on -wal/-shm
    /// sidecars, and never holds a destination journal-mode transition lock.
    public func backup(to destination: URL) throws {
        guard destination.standardizedFileURL != databaseURL.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw InputStoreError.write
        }
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "VACUUM main INTO ?", -1,
                                     &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.write }
            defer { sqlite3_finalize(statement) }
            bind(destination.path, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw InputStoreError.backupRead(
                    "VACUUM INTO snapshot: \(String(cString: sqlite3_errmsg(database)))"
                )
            }
        }
    }
    public var databaseSizeBytes: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func flushOnQueue() throws {
        guard !pending.isEmpty else { return }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO input_events(time_ms, category, name, source, is_repeat, count) VALUES(?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw InputStoreError.write
        }
        defer { sqlite3_finalize(statement) }
        for (event, sameEvents) in Dictionary(grouping: pending, by: { $0 }) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, event.timeMS)
            bind(event.category, to: 2, in: statement)
            bind(event.name, to: 3, in: statement)
            bind(event.source, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, event.isRepeat ? 1 : 0)
            sqlite3_bind_int64(statement, 6, Int64(sameEvents.count))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw InputStoreError.write
            }
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw InputStoreError.write }
        pending.removeAll(keepingCapacity: true)
    }

    private func bind(_ value: String, to column: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, column, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    public enum InputStoreError: Error { case open, read, write, backupRead(String) }
}
