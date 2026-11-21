import Foundation
import XCTest
@testable import SlashgrabCore

final class InputDashboardTests: XCTestCase {
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
}
