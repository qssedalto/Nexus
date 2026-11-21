import XCTest
@testable import SlashgrabCore

final class ClipboardCloudAutomaticSyncPolicyTests: XCTestCase {
    func testAutomaticSyncNeverStartsWithoutIndependentOptIn() {
        for cloudEnabled in [false, true] {
            for automaticEnabled in [false, true] {
                for configured in [false, true] {
                    XCTAssertEqual(
                        ClipboardCloudAutomaticSyncPolicy.maySchedule(
                            cloudEnabled: cloudEnabled,
                            automaticEnabled: automaticEnabled,
                            containerConfigured: configured
                        ),
                        cloudEnabled && automaticEnabled && configured
                    )
                }
            }
        }
    }

    func testBusyControllerAndRevokedConsentStopNewCycles() {
        XCTAssertTrue(ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
            cloudEnabled: true, automaticEnabled: true,
            containerConfigured: true, busy: false
        ))
        XCTAssertFalse(ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
            cloudEnabled: true, automaticEnabled: true,
            containerConfigured: true, busy: true
        ))
        XCTAssertFalse(ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
            cloudEnabled: false, automaticEnabled: true,
            containerConfigured: true, busy: false
        ))
        XCTAssertFalse(ClipboardCloudAutomaticSyncPolicy.mayStartCycle(
            cloudEnabled: true, automaticEnabled: false,
            containerConfigured: true, busy: false
        ))
        XCTAssertEqual(ClipboardCloudAutomaticSyncPolicy.intervalSeconds, 300)
    }
}
