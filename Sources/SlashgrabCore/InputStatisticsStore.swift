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
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { sqlite3_close(database); throw InputStoreError.open }
        let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
        sqlite3_finalize(versionStatement)
        if version < 2 {
            guard sqlite3_exec(database, "BEGIN IMMEDIATE; ALTER TABLE input_events ADD COLUMN count INTEGER NOT NULL DEFAULT 1; PRAGMA user_version=2; COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
                throw InputStoreError.write
            }
        }
        if version < 3 {
            guard sqlite3_exec(database, "BEGIN IMMEDIATE; ALTER TABLE input_events ADD COLUMN synced_at_ms INTEGER; CREATE INDEX IF NOT EXISTS input_events_pending ON input_events(synced_at_ms, id); PRAGMA user_version=3; COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
                throw InputStoreError.write
            }
        }
        if version < 4 {
            guard sqlite3_exec(database, "BEGIN IMMEDIATE; ALTER TABLE input_events ADD COLUMN remote_device_id TEXT; ALTER TABLE input_events ADD COLUMN remote_event_id INTEGER; CREATE UNIQUE INDEX IF NOT EXISTS input_events_remote ON input_events(remote_device_id, remote_event_id); PRAGMA user_version=4; COMMIT", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
                throw InputStoreError.write
            }
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

    /// Queries are half-open UTC [from,to), preserving millisecond bounds.
    /// No inferred events or interpolation is used in summaries/trends.
    public func categoryCounts(from startMS: Int64, to endMS: Int64) throws -> [InputCategoryCount] {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            let sql = """
                SELECT category, name, SUM(count), MAX(time_ms)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                GROUP BY category, name
                ORDER BY SUM(count) DESC, category, name
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
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

    public func overview(from startMS: Int64, to endMS: Int64) throws -> InputStatisticsOverview {
        try queue.sync {
            try flushOnQueue()
            var statement: OpaquePointer?
            let sql = """
                SELECT category, SUM(count)
                FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                GROUP BY category
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw InputStoreError.read }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, startMS)
            sqlite3_bind_int64(statement, 2, endMS)
            var categories: [String: Int64] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                categories[String(cString: raw)] = sqlite3_column_int64(statement, 1)
            }
            var first: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT MIN(time_ms) FROM input_events", -1, &first, nil) == SQLITE_OK,
                  let first else { throw InputStoreError.read }
            defer { sqlite3_finalize(first) }
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
                      name: String? = nil) throws -> [InputTrendBucket] {
        guard startMS >= 0, endMS >= startMS else { return [] }
        try queue.sync {
            try flushOnQueue()
            // SQLite's UTC grouping avoids DST-dependent double counting.
            // Long-term aggregate rows are already stored by event timestamps.
            // To return a stable millisecond key for all resolutions, bucket
            // in the Swift UTC calendar after selecting aggregate UTC times.
            var statement: OpaquePointer?
            let sql = """
                SELECT time_ms, category, count FROM input_events
                WHERE time_ms >= ? AND time_ms < ?
                  AND (? IS NULL OR category = ?)
                  AND (? IS NULL OR name = ?)
                ORDER BY time_ms
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
            return counts.values.map {
                InputTrendBucket(startMS: $0.0, category: $0.1, count: $0.2)
            }.sorted {
                $0.startMS == $1.startMS ? $0.category < $1.category : $0.startMS < $1.startMS
            }
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

    public func backup(to destination: URL) throws {
        guard destination.standardizedFileURL != databaseURL.standardizedFileURL else { throw InputStoreError.write }
        try queue.sync {
            try flushOnQueue()
            var target: OpaquePointer?
            guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let target else { throw InputStoreError.open }
            defer { sqlite3_close(target) }
            guard let backup = sqlite3_backup_init(target, "main", database, "main") else { throw InputStoreError.write }
            let result = sqlite3_backup_step(backup, -1)
            sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE else { throw InputStoreError.write }
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

    public enum InputStoreError: Error { case open, read, write }
}
