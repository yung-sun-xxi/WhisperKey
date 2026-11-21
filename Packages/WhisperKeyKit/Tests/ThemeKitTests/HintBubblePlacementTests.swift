import CoreGraphics
import XCTest
@testable import ThemeKit

/// Where the hint bubble opens (#220): at the pointer, as a tooltip does, inside the
/// screen. Screen coordinates, y up; the screen here is 1000 × 800 from the origin.
@MainActor
final class HintBubblePlacementTests: XCTestCase {
    private let size = CGSize(width: 200, height: 40)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func origin(_ pointer: CGPoint, screen: CGRect?) -> CGPoint {
        ThemedHintBubbleWindow.origin(of: size, pointer: pointer, below: 16, beside: 4, within: screen)
    }

    /// The top-left corner 16 under the hotspot and 4 to its right.
    func testItOpensUnderAndRightOfThePointer() {
        XCTAssertEqual(origin(CGPoint(x: 500, y: 500), screen: screen), CGPoint(x: 504, y: 444))
    }

    func testItMovesLeftAtTheScreensRightEdge() {
        XCTAssertEqual(origin(CGPoint(x: 950, y: 500), screen: screen), CGPoint(x: 800, y: 444))
    }

    /// A screen that starts right of the pointer's x, as a second display can.
    func testItMovesRightAtTheScreensLeftEdge() {
        let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        XCTAssertEqual(origin(CGPoint(x: 990, y: 500), screen: second), CGPoint(x: 1000, y: 444))
    }

    /// No room under the pointer: the bubble's bottom 4 above the hotspot.
    func testItOpensAboveThePointerAtTheScreensBottom() {
        XCTAssertEqual(origin(CGPoint(x: 500, y: 30), screen: screen), CGPoint(x: 504, y: 34))
    }

    /// A screen too short for either side: kept under its top edge.
    func testItStaysUnderTheScreensTop() {
        let short = CGRect(x: 0, y: 0, width: 1000, height: 60)
        XCTAssertEqual(origin(CGPoint(x: 500, y: 30), screen: short), CGPoint(x: 504, y: 20))
    }

    /// No screen known: the plain offset from the pointer.
    func testWithoutAScreenItIsThePlainOffset() {
        XCTAssertEqual(origin(CGPoint(x: 5000, y: -100), screen: nil), CGPoint(x: 5004, y: -156))
    }
}
