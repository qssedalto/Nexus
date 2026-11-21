import Foundation
import XCTest
@testable import SlashgrabCore

final class ClipboardShortcutSpecificationTests: XCTestCase {
    func testDefaultsAreNotSingleModifierShortcuts() {
        XCTAssertFalse(ClipboardShortcutSpecification(
            key: .v, modifiers: []).isValid)
        XCTAssertFalse(ClipboardShortcutSpecification(
            key: .v, modifiers: [.command]).isValid)
        XCTAssertTrue(ClipboardShortcutSpecification(
            key: .v, modifiers: [.control, .option]).isValid)
        XCTAssertTrue(ClipboardShortcutSpecification(
            key: .f12, modifiers: [.shift, .command]).isValid)
    }

    func testPhysicalPositionsAreDistinctAndKeysArePersistent() throws {
        let codes = ClipboardShortcutKey.allCases.map(\.physicalKeyCode)
        XCTAssertEqual(codes.count, Set(codes).count)
        XCTAssertEqual(ClipboardShortcutKey.v.physicalKeyCode, 9)
        XCTAssertEqual(ClipboardShortcutKey.space.physicalKeyCode, 49)
        XCTAssertEqual(ClipboardShortcutKey.f12.physicalKeyCode, 111)
        let spec = ClipboardShortcutSpecification(
            key: .digit7, modifiers: [.control, .option, .shift])
        XCTAssertEqual(spec.displayName, "⌃⌥⇧7")
        let json = try JSONEncoder().encode(spec)
        XCTAssertEqual(try JSONDecoder().decode(
            ClipboardShortcutSpecification.self, from: json), spec)
    }

    func testHumanReadableKeyLabelsDoNotExposeInternalPhysicalCodes() {
        XCTAssertEqual(ClipboardShortcutKey.space.displayName, "Space")
        XCTAssertEqual(ClipboardShortcutKey.a.displayName, "A")
        XCTAssertEqual(ClipboardShortcutKey.digit0.displayName, "0")
        XCTAssertEqual(ClipboardShortcutKey.f10.displayName, "F10")
    }
}
