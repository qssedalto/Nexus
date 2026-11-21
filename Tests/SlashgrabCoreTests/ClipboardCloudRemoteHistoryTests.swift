import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardCloudRemoteHistoryTests: XCTestCase {
    func testRemoteTextMirrorIsIdempotentAndNeverQueuedForAnotherCloud() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try OperationStore(url: root.appendingPathComponent("source.sqlite"))
        let target = try OperationStore(url: root.appendingPathComponent("target.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("journal.sqlite"))
        try source.record(type: "text_copy", urls: [], sourceApplication: nil,
                          detectionMethod: "clipboard", detectedTimeMS: 100,
                          clipboardText: "跨设备测试 123")
        let consent = ClipboardCloudConsent(enabled: true, includeText: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal, deviceID: "Mac-A", consent: consent
        )
        let records = try journal.pending()
        XCTAssertEqual(try target.importCloudHistory(records, consent: consent), 1)
        XCTAssertEqual(try target.importCloudHistory(records, consent: consent), 0)
        XCTAssertEqual(try target.query(from: 0, to: 200).count, 1)
        XCTAssertEqual(try target.query(from: 0, to: 200).first?.clipboardText,
                       "跨设备测试 123")
        XCTAssertEqual(try target.pendingSync().count, 0)
        XCTAssertEqual(try target.cloudEligibleHistoryPage(offset: 0).count, 0)
        let original = try XCTUnwrap(records.first)
        let deletion = original.tombstone(
            revision: ClipboardCloudRevision(counter: 2, deviceID: "Mac-B")
        )
        XCTAssertEqual(try target.importCloudHistory([deletion], consent: consent), 0)
        XCTAssertTrue(try target.query(from: 0, to: 200).isEmpty)
    }

    func testRemoteFilePathsCannotBecomePasteableLocalURLReferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try OperationStore(url: root.appendingPathComponent("source.sqlite"))
        let target = try OperationStore(url: root.appendingPathComponent("target.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("journal.sqlite"))
        try source.record(type: "copy",
                          urls: [URL(fileURLWithPath: "/Users/remote/秘密文件.pdf")],
                          sourceApplication: nil, detectionMethod: "clipboard",
                          detectedTimeMS: 500)
        let consent = ClipboardCloudConsent(
            enabled: true, includeNames: true, includePaths: true
        )
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal, deviceID: "Mac-A", consent: consent
        )
        let page = try journal.pending()
        XCTAssertEqual(try target.importCloudHistory(page, consent: consent), 1)
        let file = try XCTUnwrap(target.query(from: 0, to: 1000).first?.items.first)
        XCTAssertEqual(file.name, "秘密文件.pdf")
        XCTAssertNil(file.source, "Remote paths are metadata, not local file references")
        XCTAssertEqual(try target.importCloudHistory(page, consent: .init()), 0)
    }

    func testCloudTombstoneCannotDeleteOriginalLocalRecordWithSameUUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try OperationStore(url: root.appendingPathComponent("source.sqlite"))
        let journal = try ClipboardCloudJournal(url: root.appendingPathComponent("journal.sqlite"))
        try source.record(type: "text_copy", urls: [], sourceApplication: nil,
                          detectionMethod: "clipboard", detectedTimeMS: 5,
                          clipboardText: "Original stays")
        let consent = ClipboardCloudConsent(enabled: true, includeText: true)
        _ = try ClipboardCloudLocalSnapshot.stagePage(
            from: source, in: journal, deviceID: "Mac-A", consent: consent
        )
        let original = try XCTUnwrap(journal.pending().first)
        let deletion = original.tombstone(
            revision: ClipboardCloudRevision(counter: 2, deviceID: "Mac-B")
        )
        _ = try source.importCloudHistory([deletion], consent: consent)
        XCTAssertEqual(try source.query(from: 0, to: 10).first?.clipboardText,
                       "Original stays")
    }
}
