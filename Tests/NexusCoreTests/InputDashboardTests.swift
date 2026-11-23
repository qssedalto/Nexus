import Foundation
import SQLite3
import XCTest
@testable import NexusCore

final class InputDashboardTests: XCTestCase {
    func testSparseTrendAndLargeScrollPeakKeepCategoryTotalsIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("input.sqlite"))
        let start: Int64 = 1_800_000_000_000
        XCTAssertTrue(try store.trend(from: start, to: start + 3_600_000,
                                      resolution: .minute).isEmpty)
        store.enqueue(ClassifiedInputEvent(timeMS: start + 1_000, category: "mouse",
                                           name: "mouse_left", source: "test"))
        for _ in 0..<500 {
            store.enqueue(ClassifiedInputEvent(timeMS: start + 1_000, category: "scroll",
                                               name: "scroll_down", source: "test"))
        }
        store.enqueue(ClassifiedInputEvent(timeMS: start + 3_600_000, category: "mouse",
                                           name: "mouse_left", source: "test"))
        let withinHour = try store.trend(from: start, to: start + 3_600_000,
                                         resolution: .minute)
        XCTAssertEqual(withinHour.count, 2)
        XCTAssertEqual(withinHour.first(where: { $0.category == "mouse" })?.count, 1)
        XCTAssertEqual(withinHour.first(where: { $0.category == "scroll" })?.count, 500)
        XCTAssertEqual(try store.trend(from: start, to: start + 3_600_001,
                                       resolution: .hour, category: "mouse")
            .reduce(0) { $0 + $1.count }, 2)
    }

    func testSecondAndMinuteTrendsKeepFineTimestampBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("input.sqlite"))
        let base: Int64 = 1_800_000_000_000
        for offset in [Int64(999), 1_000, 59_999, 60_000, 60_001] {
            store.enqueue(ClassifiedInputEvent(timeMS: base + offset, category: "mouse",
                                                name: "mouse_left", source: "test"))
        }
        let seconds = try store.trend(from: base, to: base + 60_001, resolution: .second)
        XCTAssertEqual(seconds.map(\.startMS), [base, base + 1_000, base + 59_000, base + 60_000])
        XCTAssertEqual(seconds.map(\.count), [1, 1, 1, 1])
        let minutes = try store.trend(from: base, to: base + 60_001, resolution: .minute)
        XCTAssertEqual(minutes.map(\.startMS), [base, base + 60_000])
        XCTAssertEqual(minutes.map(\.count), [3, 1])
    }

    func testOverviewRankingAndExactMillisecondBuckets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("inputs.sqlite"))
        let base: Int64 = 1_795_163_532_120
        store.enqueue(ClassifiedInputEvent(timeMS: base, category: "keyboard", name: "escape", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: base, category: "keyboard", name: "escape", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: base + 1, category: "shortcut", name: "command_v", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: base + 2, category: "mouse", name: "mouse_back", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: base + 3, category: "scroll", name: "scroll_up", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: base + 4, category: "ordinary", name: "character_total", source: "test"))

        let overview = try store.overview(from: base, to: base + 4)
        XCTAssertEqual(overview.keyboard, 2)
        XCTAssertEqual(overview.mouse, 1)
        XCTAssertEqual(overview.shortcuts, 1)
        XCTAssertEqual(overview.scrolls, 1)
        XCTAssertEqual(overview.specialKeys, 2)
        XCTAssertEqual(overview.firstEventMS, base)
        let categories = try store.categoryCounts(from: base, to: base + 4)
        XCTAssertEqual(categories.first(where: { $0.category == "keyboard" })?.count, 2)
        let row = try store.trend(from: base, to: base + 4, resolution: .hour,
                                  category: "keyboard", name: "escape")
        XCTAssertEqual(row.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(try store.counts(from: base + 4, to: base + 5)
            .first(where: { $0.name == "character_total" })?.count, 1)
    }

    func testDayWeekAndMonthTrendsUseUTCBucketsAcrossYear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("inputs.sqlite"))
        let formatter = ISO8601DateFormatter()
        let stamps = ["2026-12-31T23:59:59Z", "2027-01-01T00:00:00Z"]
        let millis = stamps.compactMap { formatter.date(from: $0) }
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        XCTAssertEqual(millis.count, 2)
        for stamp in millis {
            store.enqueue(ClassifiedInputEvent(timeMS: stamp, category: "system",
                                                name: "volume_up", source: "test"))
        }
        let start = millis[0] - 1000
        let end = millis[1] + 1000
        for resolution: InputTrendResolution in [.day, .week, .month] {
            let rows = try store.trend(from: start, to: end, resolution: resolution,
                                        category: "system", name: "volume_up")
            XCTAssertEqual(rows.reduce(0) { $0 + $1.count }, 2)
            // ISO-8601 weeks span the year boundary in this example.
            XCTAssertEqual(rows.count, resolution == .week ? 1 : 2)
        }
        XCTAssertEqual(try store.trend(from: millis[1], to: end, resolution: .day)
            .reduce(0) { $0 + $1.count }, 1)
    }
    func testPartialSchemaMigrationKeepsPreviousStatisticsAndAddsMissingColumns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("inputs.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let partialSchema = """
            CREATE TABLE input_events (
              id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, category TEXT NOT NULL,
              name TEXT NOT NULL, source TEXT NOT NULL, is_repeat INTEGER NOT NULL,
              count INTEGER NOT NULL DEFAULT 1
            );
            INSERT INTO input_events VALUES (1, 12001, 'keyboard', 'escape', 'old', 0, 42);
            PRAGMA user_version=1;
            """
        XCTAssertEqual(sqlite3_exec(db, partialSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try InputStatisticsStore(url: path)
        XCTAssertEqual(try store.counts(from: 12000, to: 12002)
            .first(where: { $0.name == "escape" })?.count, 42)
        XCTAssertEqual(try store.pendingSync().count, 1)
        let summary = try store.overview(from: 12000, to: 12002)
        XCTAssertEqual(summary.specialKeys, 42)
    }


    func testPerSourceStatisticsNeverAttributeQuartzEventsToHIDDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("input.sqlite"))
        let hid = "iohid_consumer:vendor_1234_product_5678_location_2"
        store.enqueue(ClassifiedInputEvent(timeMS: 2000, category: "system",
                                           name: "volume_up", source: hid))
        store.enqueue(ClassifiedInputEvent(timeMS: 2001, category: "system",
                                           name: "volume_up", source: "appkit_system_defined"))
        store.enqueue(ClassifiedInputEvent(timeMS: 2002, category: "mouse",
                                           name: "mouse_left", source: "quartz_uptime"))
        let all = try store.sourceCounts(from: 2000, to: 2003)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.first(where: { $0.source == hid })?.count, 1)
        let overview = try store.overview(from: 2000, to: 2003, source: hid)
        XCTAssertEqual(overview.specialKeys, 1)
        XCTAssertEqual(overview.mouse, 0)
        XCTAssertEqual(overview.firstEventMS, 2000)
        XCTAssertEqual(try store.categoryCounts(from: 2000, to: 2003, source: hid).count, 1)
        XCTAssertEqual(try store.trend(from: 2000, to: 2003, resolution: .hour,
                                       source: hid).reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(try store.sourceCounts(from: 2001, to: 2003).count, 2)
    }

    func testUTCHourBucketsAcrossDenverDaylightSavingTransitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("input.sqlite"))
        let formatter = ISO8601DateFormatter()
        let transitions = [
            ["2026-03-08T08:59:59Z", "2026-03-08T09:00:00Z"],
            ["2026-11-01T07:59:59Z", "2026-11-01T08:00:00Z"],
        ]
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/Denver")!
        let hours = transitions.map { pair -> [Date] in pair.compactMap(formatter.date(from:)) }
        XCTAssertEqual(hours.map(\.count), [2, 2])
        // Spring skips one local hour; fall repeats it. The underlying UTC
        // event bucket must not merge or duplicate either physical hour.
        XCTAssertEqual(
            local.component(.hour, from: hours[0][0]),
            1
        )
        XCTAssertEqual(local.component(.hour, from: hours[0][1]), 3)
        XCTAssertEqual(local.component(.hour, from: hours[1][0]), 1)
        XCTAssertEqual(local.component(.hour, from: hours[1][1]), 1)
        for (idx, pair) in hours.enumerated() {
            let times = pair.map { Int64($0.timeIntervalSince1970 * 1_000) }
            store.enqueue(ClassifiedInputEvent(
                timeMS: times[0], category: "mouse", name: "mouse_left",
                source: "dst-\(idx)"
            ))
            store.enqueue(ClassifiedInputEvent(
                timeMS: times[1], category: "mouse", name: "mouse_left",
                source: "dst-\(idx)"
            ))
            // Another event category shares the exact wall-clock transition,
            // but category filtering must not double-count it.
            store.enqueue(ClassifiedInputEvent(
                timeMS: times[1], category: "scroll", name: "scroll_up",
                source: "dst-\(idx)"
            ))
            let rows = try store.trend(
                from: times[0] - 1000, to: times[1] + 1000,
                resolution: .hour, category: "mouse", source: "dst-\(idx)"
            )
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map(\.count), [1, 1])
            XCTAssertEqual(rows[1].startMS - rows[0].startMS, 3_600_000)
            let all = try store.trend(
                from: times[0] - 1000, to: times[1] + 1000,
                resolution: .hour, source: "dst-\(idx)"
            )
            XCTAssertEqual(all.reduce(Int64(0)) { $0 + $1.count }, 3)
        }
    }

}
