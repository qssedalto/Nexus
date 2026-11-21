import Foundation
import XCTest
@testable import SlashgrabCore

final class InputCloudBackupRestoreTests: XCTestCase {
    func testRestoringBackupPreservesCurrentRowsAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try InputStatisticsStore(url: root.appendingPathComponent("source.sqlite"))
        source.enqueue(ClassifiedInputEvent(timeMS: 1000, category: "keyboard",
                                            name: "escape", source: "quartz_uptime"))
        source.enqueue(ClassifiedInputEvent(timeMS: 1001, category: "mouse",
                                            name: "mouse_back", source: "quartz_uptime"))
        let backup = root.appendingPathComponent("NexusStatistics.sqlite")
        try source.backup(to: backup)

        let current = try InputStatisticsStore(url: root.appendingPathComponent("current.sqlite"))
        // Simulate a running Mac that already contains the first backed-up
        // local row, plus additional statistics that must never disappear.
        current.enqueue(ClassifiedInputEvent(timeMS: 1000, category: "keyboard",
                                             name: "escape", source: "quartz_uptime"))
        current.enqueue(ClassifiedInputEvent(timeMS: 2000, category: "shortcut",
                                             name: "command_v", source: "quartz_uptime"))
        let imported = try current.restoreBackup(from: backup, deviceID: "icloud:device-A")
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(try current.restoreBackup(from: backup, deviceID: "icloud:device-A"), 0)
        let results = try current.categoryCounts(from: 0, to: 2001)
        XCTAssertEqual(results.first(where: { $0.name == "escape" })?.count, 1)
        XCTAssertEqual(results.first(where: { $0.name == "mouse_back" })?.count, 1)
        XCTAssertEqual(results.first(where: { $0.name == "command_v" })?.count, 1)
    }

    func testTwoMacBackupCycleDoesNotDuplicateOriginalEventCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try InputStatisticsStore(url: root.appendingPathComponent("a.sqlite"))
        let b = try InputStatisticsStore(url: root.appendingPathComponent("b.sqlite"))
        a.enqueue(ClassifiedInputEvent(timeMS: 1000, category: "keyboard",
                                       name: "escape", source: "quartz_uptime"))
        b.enqueue(ClassifiedInputEvent(timeMS: 2000, category: "mouse",
                                       name: "mouse_left", source: "quartz_uptime"))
        let snapshotA = root.appendingPathComponent("A.sqlite")
        try a.backup(to: snapshotA)
        XCTAssertEqual(try b.restoreBackup(from: snapshotA, deviceID: "icloud:A"), 1)
        let snapshotB = root.appendingPathComponent("B.sqlite")
        try b.backup(to: snapshotB)
        // B's backup contains B's original event and the previously imported
        // A event. The latter must not be re-attributed to B and counted twice.
        XCTAssertEqual(try a.restoreBackup(from: snapshotB, deviceID: "icloud:B"), 1)
        XCTAssertEqual(try a.restoreBackup(from: snapshotB, deviceID: "icloud:B"), 0)
        let counts = try a.categoryCounts(from: 0, to: 3000)
        XCTAssertEqual(counts.first(where: { $0.name == "escape" })?.count, 1)
        XCTAssertEqual(counts.first(where: { $0.name == "mouse_left" })?.count, 1)
    }

    func testCorruptBackupDoesNotDeleteCurrentStatistics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("current.sqlite"))
        store.enqueue(ClassifiedInputEvent(timeMS: 1000, category: "system",
                                           name: "volume_up", source: "iohid_consumer"))
        let corrupted = root.appendingPathComponent("NexusStatistics.sqlite")
        try Data("this is not a SQLite database".utf8).write(to: corrupted)
        XCTAssertThrowsError(try store.restoreBackup(from: corrupted, deviceID: "icloud:test"))
        XCTAssertEqual(try store.counts(from: 0, to: 2000)
            .first(where: { $0.name == "volume_up" })?.count, 1)
    }
}
