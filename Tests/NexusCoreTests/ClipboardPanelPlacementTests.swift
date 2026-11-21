import CoreGraphics
import XCTest
@testable import NexusCore

final class ClipboardPanelPlacementTests: XCTestCase {
    func testFitsSmallLaptopScreenWithoutGoingOffDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 640, height: 480)
        let frame = ClipboardPanelPlacement.frame(
            inside: screen, requestedSize: CGSize(width: 900, height: 480)
        )
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertLessThanOrEqual(frame.width, 640)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    func testExternalMonitorWithNegativeOriginRemainsContained() {
        let screen = CGRect(x: -2560, y: 120, width: 2560, height: 1440)
        let frame = ClipboardPanelPlacement.frame(
            inside: screen, requestedSize: CGSize(width: 900, height: 455)
        )
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(frame.minY, screen.minY + 20, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    func testTallAndNarrowDisplayBoundsDoNotDependOnRetinaPixels() {
        let screen = CGRect(x: 1440, y: -900, width: 720, height: 900)
        let frame = ClipboardPanelPlacement.frame(
            inside: screen, requestedSize: CGSize(width: 900, height: 640)
        )
        XCTAssertLessThanOrEqual(frame.width, screen.width)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }
}
