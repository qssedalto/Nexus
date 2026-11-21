import XCTest
@testable import NexusCore

final class StatisticsDeletionConfirmationPolicyTests: XCTestCase {
    func testThousandExplicitConfirmationsBeforeDeletion() {
        let steps = StatisticsDeletionConfirmationPolicy.requiredSteps
        XCTAssertEqual(steps, 1_000)
        let prompts = (1...steps).compactMap {
            StatisticsDeletionConfirmationPolicy.prompt(forStep: $0)
        }
        XCTAssertEqual(prompts.count, steps)
        XCTAssertGreaterThanOrEqual(Set(prompts).count, 10)
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 999))
        XCTAssertTrue(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 1_000))
        XCTAssertEqual(
            StatisticsDeletionConfirmationPolicy.prompt(forStep: 1_000),
            "Final confirmation: permanently delete these local statistics."
        )
    }

    func testSequentialProgressionIsBoundedAndCannotSkipAStep() {
        var step = 1
        for expectedNext in 2...1_000 {
            XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: step))
            step = StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: step) ?? -1
            XCTAssertEqual(step, expectedNext)
        }
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 1_000))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 0))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 1_001))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.prompt(forStep: 0))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.prompt(forStep: 1_001))
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 0))
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 1_001))
    }
}
