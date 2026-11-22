import XCTest
@testable import NexusCore

final class PrivacyFeatureSwitchPolicyTests: XCTestCase {
    func testInputMasterSwitchOverridesSavedPermission() {
        XCTAssertTrue(PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: true, paused: false, permissionGranted: true))
        XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: false, paused: false, permissionGranted: true))
        XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: true, paused: true, permissionGranted: true))
        XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldMonitorInput(
            enabled: true, paused: false, permissionGranted: false))
    }

    func testStatisticsUploadConsentAppliesToManualAndAutomaticCalls() {
        for automaticRun in [false, true] {
            XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldUploadStatistics(
                enabled: false, automaticRun: automaticRun, automatic: true))
        }
        XCTAssertTrue(PrivacyFeatureSwitchPolicy.shouldUploadStatistics(
            enabled: true, automaticRun: false, automatic: false))
        XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldUploadStatistics(
            enabled: true, automaticRun: true, automatic: false))
        XCTAssertTrue(PrivacyFeatureSwitchPolicy.shouldUploadStatistics(
            enabled: true, automaticRun: true, automatic: true))
    }
    func testRevokedAPITokenNeverFallsBackToNewOrLegacyKeychain() {
        for legacy in [false, true] {
            for fallbackDisabled in [false, true] {
                XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldReadStoredAPIToken(
                    credentialRevoked: true,
                    isLegacyService: legacy,
                    legacyFallbackDisabled: fallbackDisabled
                ))
            }
        }
    }

    func testLegacyCredentialRequiresSeparateFallbackPermission() {
        XCTAssertTrue(PrivacyFeatureSwitchPolicy.shouldReadStoredAPIToken(
            credentialRevoked: false, isLegacyService: false,
            legacyFallbackDisabled: true
        ))
        XCTAssertTrue(PrivacyFeatureSwitchPolicy.shouldReadStoredAPIToken(
            credentialRevoked: false, isLegacyService: true,
            legacyFallbackDisabled: false
        ))
        XCTAssertFalse(PrivacyFeatureSwitchPolicy.shouldReadStoredAPIToken(
            credentialRevoked: false, isLegacyService: true,
            legacyFallbackDisabled: true
        ))
    }

}
