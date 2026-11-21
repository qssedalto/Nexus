import Foundation
import XCTest
@testable import NexusCore

final class ClipboardCloudForegroundSyncPolicyTests: XCTestCase {
    func testOffByDefaultAndCloudAvailabilityAreBothRequired() {
        let now = Date(timeIntervalSince1970: 1000)
        for cloud in [false, true] {
            for foreground in [false, true] {
                for configured in [false, true] {
                    let allowed = ClipboardCloudForegroundSyncPolicy.mayAttempt(
                        cloudEnabled: cloud, foregroundEnabled: foreground,
                        containerConfigured: configured, busy: false,
                        lastAttempt: nil, now: now
                    )
                    XCTAssertEqual(allowed, cloud && foreground && configured)
                }
            }
        }
    }

    func testThrottledForegroundReactivationAndBusyState() {
        let first = Date(timeIntervalSince1970: 1000)
        func allowed(_ seconds: TimeInterval, busy: Bool = false) -> Bool {
            ClipboardCloudForegroundSyncPolicy.mayAttempt(
                cloudEnabled: true, foregroundEnabled: true,
                containerConfigured: true, busy: busy,
                lastAttempt: first,
                now: first.addingTimeInterval(seconds)
            )
        }
        XCTAssertFalse(allowed(0))
        XCTAssertFalse(allowed(299))
        XCTAssertTrue(allowed(300))
        XCTAssertTrue(allowed(601))
        XCTAssertFalse(allowed(301, busy: true))
        XCTAssertFalse(allowed(-5))
    }
}
