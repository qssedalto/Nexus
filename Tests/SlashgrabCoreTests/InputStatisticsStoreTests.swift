import Foundation
import XCTest
@testable import SlashgrabCore

final class InputStatisticsStoreTests: XCTestCase {
    func testMillisecondBoundariesAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.sqlite")
        let start: Int64 = 1_795_163_532_125
        do {
            let store = try InputStatisticsStore(url: url)
            for _ in 0..<1000 {
                store.enqueue(ClassifiedInputEvent(timeMS: start, category: "mouse", name: "mouse_left", source: "test"))
            }
            store.enqueue(ClassifiedInputEvent(timeMS: start + 1, category: "keyboard", name: "escape", source: "test"))
            XCTAssertEqual(try store.counts(from: start, to: start + 1).first?.count, 1000)
            XCTAssertEqual(try store.counts(from: start + 1, to: start + 2).first?.name, "escape")
            let pending = try store.pendingSync()
            XCTAssertEqual(pending.reduce(0) { $0 + $1.count }, 1001)
            try store.markSynced(ids: pending.map(\.id), deviceID: "device-a")
            XCTAssertTrue(try store.pendingSync().isEmpty)
            XCTAssertEqual(try store.integrityCheck(), "ok")
            let backup = directory.appendingPathComponent("backup.sqlite")
            try store.backup(to: backup)
            XCTAssertEqual(try InputStatisticsStore(url: backup).counts(from: start, to: start + 2).reduce(0) { $0 + $1.count }, 1001)
            XCTAssertGreaterThan(try store.delete(from: start, to: start + 1), 0)
            XCTAssertEqual(try store.counts(from: start, to: start + 2).reduce(0) { $0 + $1.count }, 1)
        }
        let reopened = try InputStatisticsStore(url: url)
        XCTAssertEqual(try reopened.counts(from: start, to: start + 2).reduce(0) { $0 + $1.count }, 1)
    }

    func testRemoteRestoreDeduplicatesByDeviceAndEventID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try InputStatisticsStore(url: directory.appendingPathComponent("stats.sqlite"))
        store.enqueue(ClassifiedInputEvent(timeMS: 1_000, category: "mouse", name: "mouse_left", source: "test"))
        let local = try XCTUnwrap(store.pendingSync().first)
        try store.markSynced(ids: [local.id], deviceID: "device-a")
        let data = Data("[{\"device_id\":\"device-a\",\"id\":\(local.id),\"time_ms\":1000,\"category\":\"mouse\",\"name\":\"mouse_left\",\"count\":1},{\"device_id\":\"device-b\",\"id\":\(local.id),\"time_ms\":1000,\"category\":\"mouse\",\"name\":\"mouse_left\",\"count\":2}]".utf8)
        let remote = try JSONDecoder().decode([RemoteInputEvent].self, from: data)
        XCTAssertEqual(try store.importRemote(remote), 1)
        XCTAssertEqual(try store.importRemote(remote), 0)
        XCTAssertEqual(try store.counts(from: 1_000, to: 1_001).first?.count, 3)
        XCTAssertTrue(try store.pendingSync().isEmpty)
    }
}
