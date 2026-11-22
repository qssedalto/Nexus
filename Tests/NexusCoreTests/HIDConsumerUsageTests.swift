import XCTest
@testable import NexusCore

final class HIDConsumerUsageTests: XCTestCase {
    func testDocumentedConsumerUsageMapping() {
        XCTAssertEqual(HIDConsumerUsage.name(for: 0x6F), "brightness_up")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0x70), "brightness_down")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0xE9), "volume_up")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0xEA), "volume_down")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0xCD), "play_pause")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0x221), "spotlight_search")
        XCTAssertEqual(HIDConsumerUsage.name(for: 0x29D), "fn")
        XCTAssertNil(HIDConsumerUsage.name(for: 0xFFFF))
    }

    func testF21ThroughF24DoNotClassifyOrdinaryTyping() {
        XCTAssertEqual(HIDConsumerUsage.functionName(forKeyboardUsage: 0x70), "f21")
        XCTAssertEqual(HIDConsumerUsage.functionName(forKeyboardUsage: 0x73), "f24")
        XCTAssertNil(HIDConsumerUsage.functionName(forKeyboardUsage: 0x04))
        XCTAssertNil(HIDConsumerUsage.functionName(forKeyboardUsage: 0x3A))
        XCTAssertNil(HIDConsumerUsage.functionName(forKeyboardUsage: 0xFFFF))
    }

    func testSystemDefinedUnknownCodesAreNotGuessed() {
        XCTAssertEqual(HIDConsumerUsage.macSystemKeyName(for: 16), "play_pause")
        XCTAssertEqual(HIDConsumerUsage.macSystemKeyName(for: 2), "brightness_up")
        XCTAssertNil(HIDConsumerUsage.macSystemKeyName(for: 160))
    }
    func testOptInDiagnosticIncludesOnlyPhysicalMetadata() {
        let legacy = InputDiagnosticEvent(timeMS: 1, name: "f1", source: "test", supported: true)
        XCTAssertNil(legacy.keyCode)
        XCTAssertNil(legacy.eventKind)
        XCTAssertTrue(legacy.modifiers.isEmpty)
        XCTAssertFalse(legacy.isRepeat)

        let sample = InputDiagnosticEvent(
            timeMS: 2, name: "command_f1", source: "quartz_uptime",
            supported: true, keyCode: 122, modifiers: ["Command"],
            eventKind: "chord", isRepeat: true
        )
        XCTAssertEqual(sample.keyCode, 122)
        XCTAssertEqual(sample.modifiers, ["Command"])
        XCTAssertEqual(sample.eventKind, "chord")
        XCTAssertTrue(sample.isRepeat)
    }

}
