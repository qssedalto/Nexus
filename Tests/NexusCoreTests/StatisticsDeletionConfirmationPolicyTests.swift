import XCTest
@testable import SlashgrabCore

final class StatisticsDeletionConfirmationPolicyTests: XCTestCase {
    func testTenDistinctConfirmationsBeforeDeletion() {
        let steps = StatisticsDeletionConfirmationPolicy.requiredSteps
        XCTAssertEqual(steps, 10)
        let prompts = (1...steps).compactMap {
            StatisticsDeletionConfirmationPolicy.prompt(forStep: $0)
        }
        XCTAssertEqual(prompts.count, 10)
        XCTAssertEqual(Set(prompts).count, 10)
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 9))
        XCTAssertTrue(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 10))
    }

    func testProgressionIsBoundedAndCannotSkipAStep() {
        var step = 1
        for expectedNext in 2...10 {
            XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: step))
            step = StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: step) ?? -1
            XCTAssertEqual(step, expectedNext)
        }
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 10))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 0))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.nextStep(afterConfirmed: 11))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.prompt(forStep: 0))
        XCTAssertNil(StatisticsDeletionConfirmationPolicy.prompt(forStep: 11))
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 0))
        XCTAssertFalse(StatisticsDeletionConfirmationPolicy.allowsDeletion(afterConfirmed: 11))
    }
}
