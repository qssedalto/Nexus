import Foundation
import XCTest
@testable import NexusCore

final class OperationSyncPrivacyTests: XCTestCase {
    func testRemoteHistoryRedactsPastTextAndPathsWhenCurrentConsentIsNarrow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OperationStore(url: root.appendingPathComponent("operations.sqlite"))
        let url = URL(fileURLWithPath: "/tmp/private-folder/confidential.txt")
        try store.record(type: "copy", urls: [url], sourceApplication: nil,
                         detectionMethod: "clipboard", detectedTimeMS: 1_001,
                         target: "/tmp/private-destination", clipboardText: "private-body")
        let original = try XCTUnwrap(store.query(from: 1_000, to: 1_002).first)
        let transmitted = SyncOperation(record: original, includePaths: true, includeText: true)
        // Decode a genuine wire representation to exercise the same path as
        // an older server record that contains more data than is now permitted.
        let serverVersion = try JSONDecoder().decode(
            SyncOperation.self, from: JSONEncoder().encode(transmitted)
        )
        let limited = serverVersion.redacted(includePaths: false, includeText: false)
        XCTAssertEqual(limited.id, serverVersion.id)
        XCTAssertEqual(limited.type, serverVersion.type)
        XCTAssertEqual(limited.detectedTimeMS, 1_001)
        XCTAssertEqual(limited.items.count, 1)
        XCTAssertEqual(limited.items[0].name, "confidential.txt")
        XCTAssertNil(limited.items[0].source)
        XCTAssertNil(limited.target)
        XCTAssertNil(limited.clipboardText)

        let allowedPaths = serverVersion.redacted(includePaths: true, includeText: false)
        XCTAssertEqual(allowedPaths.items[0].source, url.path)
        XCTAssertEqual(allowedPaths.target, "/tmp/private-destination")
        XCTAssertNil(allowedPaths.clipboardText)

        let allowedText = serverVersion.redacted(includePaths: false, includeText: true)
        XCTAssertNil(allowedText.items[0].source)
        XCTAssertNil(allowedText.target)
        XCTAssertEqual(allowedText.clipboardText, "private-body")
    }

    func testRedactedRemotePageCannotPersistUnapprovedFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try OperationStore(url: root.appendingPathComponent("local.sqlite"))
        let id = UUID().uuidString
        let json = """
        {
          "device_id": "remote-Mac",
          "operation": {
            "id": "\(id)",
            "type": "copy",
            "detected_time_ms": 1000,
            "detection_method": "clipboard",
            "status": "clipboard_detected",
            "target": "/secret/destination",
            "clipboard_text": "earlier authorized text",
            "items": [{
              "position": 0,
              "name": "report.pdf",
              "source": "/secret/report.pdf",
              "kind": "document"
            }]
          }
        }
        """
        let serverRecord = try JSONDecoder().decode(
            RemoteOperationRecord.self, from: Data(json.utf8))
        let safeRecord = serverRecord.redacted(includePaths: false, includeText: false)
        XCTAssertEqual(try local.importRemote([safeRecord]), 1)
        let saved = try XCTUnwrap(local.query(from: 1_000, to: 1_001).first)
        XCTAssertNil(saved.target)
        XCTAssertNil(saved.clipboardText)
        XCTAssertEqual(saved.items.first?.name, "report.pdf")
        XCTAssertNil(saved.items.first?.source)
        XCTAssertEqual(saved.detectionMethod, "remote_restore")
    }
}
