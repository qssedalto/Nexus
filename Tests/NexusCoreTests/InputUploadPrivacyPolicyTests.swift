import Foundation
import XCTest
@testable import NexusCore

final class InputUploadPrivacyPolicyTests: XCTestCase {
    private func row(_ id: Int64, _ time: Int64, _ category: String,
                     _ name: String, count: Int64 = 1) -> SyncInputEvent {
        SyncInputEvent(id: id, timeMS: time, category: category,
                       name: name, count: count)
    }

    func testOrdinaryCharacterInputsAreAggregatedByUTCHour() throws {
        let source = [
            row(1, 1_003, "ordinary", "character_total"),
            row(2, 2_575, "ordinary", "character_total", count: 2),
            row(3, 3_599_999, "ordinary", "character_total"),
            row(4, 3_600_005, "ordinary", "character_total")
        ]
        for precise in [false, true] {
            let plan = try InputUploadPrivacyPolicy.prepare(
                source, preciseNonTextEvents: precise
            )
            XCTAssertEqual(plan.events.count, 2)
            XCTAssertEqual(plan.events.map(\.timeMS), [0, 3_600_000])
            XCTAssertEqual(plan.events.map(\.count), [4, 1])
            XCTAssertEqual(plan.events.map(\.id), [1, 4])
            XCTAssertEqual(plan.sourceIDs(forAcknowledgedUploadIDs: [1]), [1, 2, 3])
            XCTAssertEqual(plan.sourceIDs(forAcknowledgedUploadIDs: [4]), [4])
            XCTAssertNil(plan.sourceIDs(forAcknowledgedUploadIDs: [1, 1]))
            XCTAssertNil(plan.sourceIDs(forAcknowledgedUploadIDs: [8]))
            XCTAssertNil(plan.sourceIDs(forAcknowledgedUploadIDs: []))
        }
    }

    func testNonTextRequiresSeparatePermissionForPreciseUpload() throws {
        let source = [
            row(11, 60_101, "mouse", "mouse_left"),
            row(12, 60_850, "mouse", "mouse_left"),
            row(13, 60_900, "keyboard", "escape"),
            row(14, 60_999, "ordinary", "character_total")
        ]
        let coarse = try InputUploadPrivacyPolicy.prepare(
            source, preciseNonTextEvents: false
        )
        XCTAssertEqual(coarse.events.count, 3)
        XCTAssertEqual(coarse.events.map(\.timeMS), [60_000, 60_000, 0])
        XCTAssertEqual(coarse.events.map(\.count), [2, 1, 1])
        XCTAssertEqual(coarse.sourceIDs(forAcknowledgedUploadIDs: [11, 14]),
                       [11, 12, 14])

        let precise = try InputUploadPrivacyPolicy.prepare(
            source, preciseNonTextEvents: true
        )
        XCTAssertEqual(precise.events.count, 4)
        XCTAssertEqual(precise.events.map(\.timeMS),
                       [60_101, 60_850, 60_900, 0])
        XCTAssertEqual(precise.sourceIDs(forAcknowledgedUploadIDs: [12]), [12])
    }

    func testServerAcknowledgementMarksOnlyItsOriginalRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InputStatisticsStore(url: root.appendingPathComponent("stats.sqlite"))
        for index: Int64 in 1...5 {
            store.enqueue(ClassifiedInputEvent(
                timeMS: 1_000 + index, category: index < 5 ? "ordinary" : "mouse",
                name: index < 5 ? "character_total" : "mouse_left", source: "test"
            ))
        }
        let pending = try store.pendingSync()
        XCTAssertEqual(pending.count, 5)
        let plan = try InputUploadPrivacyPolicy.prepare(
            pending, preciseNonTextEvents: false
        )
        XCTAssertEqual(plan.events.count, 2)
        let characterID = try XCTUnwrap(plan.events.first {
            $0.category == "ordinary"
        }?.id)
        let originalIDs = try XCTUnwrap(plan.sourceIDs(
            forAcknowledgedUploadIDs: [characterID]
        ))
        XCTAssertEqual(originalIDs.count, 4)
        try store.markSynced(ids: originalIDs, deviceID: "test-device")

        let remaining = try store.pendingSync()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.category, "mouse")
        let mouseID = try XCTUnwrap(plan.events.first {
            $0.category == "mouse"
        }?.id)
        try store.markSynced(
            ids: try XCTUnwrap(plan.sourceIDs(forAcknowledgedUploadIDs: [mouseID])),
            deviceID: "test-device"
        )
        XCTAssertTrue(try store.pendingSync().isEmpty)
        XCTAssertEqual(try store.counts(from: 0, to: 10_000)
            .reduce(Int64(0)) { $0 + $1.count }, 5,
            "Network aggregation must not change local statistics")
    }

    func testRejectInvalidOrOverflowingRecordsRatherThanLosingCounts() throws {
        let invalid = [row(1, 100, "ordinary", "character_total", count: -1)]
        XCTAssertThrowsError(try InputUploadPrivacyPolicy.prepare(
            invalid, preciseNonTextEvents: false
        ))
        let duplicate = [
            row(1, 100, "ordinary", "character_total"),
            row(1, 101, "ordinary", "character_total")
        ]
        XCTAssertThrowsError(try InputUploadPrivacyPolicy.prepare(
            duplicate, preciseNonTextEvents: false
        ))
        let overflow = [
            row(1, 100, "ordinary", "character_total", count: Int64.max),
            row(2, 101, "ordinary", "character_total")
        ]
        XCTAssertThrowsError(try InputUploadPrivacyPolicy.prepare(
            overflow, preciseNonTextEvents: false
        ))
    }
}
