import Foundation
import NexusCore
import Testing
@testable import Nexus

@Suite("Input trend presentation")
struct InputTrendPresentationTests {
    private func store() throws -> (InputStatisticsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return (try InputStatisticsStore(url: directory.appendingPathComponent("trend.sqlite")),
                directory)
    }

    @Test("Empty and sparse ranges retain original event times")
    func sparseDomainAndHover() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start: Int64 = 1_800_000_000_000
        let full = Date(timeIntervalSince1970: Double(start) / 1000)
            ... Date(timeIntervalSince1970: Double(start + 86_400_000) / 1000)
        let empty = InputTrendDisplayData(buckets: [], resolution: .hour,
                                          visibleCategories: ["mouse"])
        #expect(empty.domain(in: full, focused: true) == full)
        #expect(empty.nearestStart(to: 40) { _ in 40 } == nil)

        let first = start + 3_600_000
        let second = start + 18 * 3_600_000
        store.enqueue(ClassifiedInputEvent(timeMS: first, category: "mouse",
                                           name: "mouse_left", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: second, category: "mouse",
                                           name: "mouse_left", source: "test"))
        let rows = try store.trend(from: start, to: start + 86_400_000, resolution: .hour)
        let model = InputTrendDisplayData(buckets: rows, resolution: .hour,
                                          visibleCategories: ["mouse"])
        #expect(model.starts == [first, second])
        #expect(model.runs(for: "mouse").map(\.count) == [1, 1])
        #expect(model.domain(in: full, focused: false) == full)
        #expect(model.domain(in: full, focused: true).upperBound
                .timeIntervalSince(model.domain(in: full, focused: true).lowerBound) < 86_400)
        #expect(model.nearestStart(to: 51) { $0 == first ? 50 : 300 } == first)
        #expect(model.nearestStart(to: 120) { $0 == first ? 50 : 300 } == nil)
        #expect(model.total(at: first) == 1)
    }

    @Test("Dense input and a large scroll count use separate category values")
    func denseAndScroll() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start: Int64 = 1_800_000_000_000
        for index in 0..<72 {
            store.enqueue(ClassifiedInputEvent(timeMS: start + Int64(index) * 3_600_000,
                                               category: "ordinary", name: "character_total",
                                               source: "test"))
        }
        for _ in 0..<5_000 {
            store.enqueue(ClassifiedInputEvent(timeMS: start + 3_600_000, category: "scroll",
                                               name: "scroll_down", source: "test"))
        }
        let rows = try store.trend(from: start, to: start + 73 * 3_600_000, resolution: .hour)
        let all = InputTrendDisplayData(buckets: rows, resolution: .hour,
                                        visibleCategories: ["ordinary", "scroll"])
        #expect(all.runs(for: "ordinary").map(\.count) == [72])
        #expect(all.total(for: "ordinary") == 72)
        #expect(all.total(for: "scroll") == 5_000)
        #expect(all.total(at: start + 3_600_000) == 5_001)
        let keyboardOnly = InputTrendDisplayData(buckets: rows, resolution: .hour,
                                                 visibleCategories: ["ordinary"])
        #expect(keyboardOnly.total(at: start + 3_600_000) == 1)
        #expect(keyboardOnly.details(at: start + 3_600_000).count == 1)
    }

    @Test("Repeated local hour remains two distinct UTC buckets")
    func daylightSavingHour() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let formatter = ISO8601DateFormatter()
        let first = Int64(try #require(formatter.date(from: "2026-11-01T07:30:00Z"))
            .timeIntervalSince1970 * 1_000)
        let second = first + 3_600_000
        store.enqueue(ClassifiedInputEvent(timeMS: first, category: "mouse",
                                           name: "mouse_left", source: "test"))
        store.enqueue(ClassifiedInputEvent(timeMS: second, category: "mouse",
                                           name: "mouse_left", source: "test"))
        let rows = try store.trend(from: first - 3_600_000, to: second + 3_600_000,
                                   resolution: .hour)
        let model = InputTrendDisplayData(buckets: rows, resolution: .hour,
                                          visibleCategories: ["mouse"])
        #expect(model.starts.count == 2)
        #expect(model.starts[1] - model.starts[0] == 3_600_000)
        #expect(model.bucketEnd(after: model.starts[0]) == model.starts[1])
        #expect(model.total(at: model.starts[0]) == 1)
        #expect(model.total(at: model.starts[1]) == 1)
    }
}
