import CoreGraphics
import XCTest
@testable import QuickPaste

/// Geometry the panel and the hit test must agree on. Spelled out here rather than read
/// back from the implementation, so a change to a constant fails a test instead of moving
/// the goalposts along with itself.
private enum Geometry {
    static let width: CGFloat = 320
    static let verticalPadding: CGFloat = 9
    static let headerBand: CGFloat = 14 + 4      // header height + its bottom spacing
    static let rowHeight: CGFloat = 26
    static let gap: CGFloat = 10
    static let cursorInsetX: CGFloat = 16

    /// Height of a panel showing `n` entries.
    static func height(_ n: Int) -> CGFloat {
        verticalPadding * 2 + headerBand + CGFloat(max(n, 1)) * rowHeight
    }

    /// Screen y of the top edge of the rows band for a panel with this frame.
    static func rowsTop(_ frame: CGRect) -> CGFloat {
        frame.maxY - verticalPadding - headerBand
    }

    /// A point comfortably inside row `slot`, counted from the top of the list.
    static func centreOfSlot(_ slot: Int, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.midX,
            y: rowsTop(frame) - (CGFloat(slot) + 0.5) * rowHeight
        )
    }
}

/// A panel of `n` entries placed at a fixed origin, for the hit tests.
private func panelFrame(entryCount: Int, origin: CGPoint = CGPoint(x: 500, y: 400)) -> CGRect {
    CGRect(
        origin: origin,
        size: CGSize(width: Geometry.width, height: Geometry.height(entryCount))
    )
}

final class QuickPasteLayoutTests: XCTestCase {

    // MARK: - Panel size

    func testPanelHeightGrowsByOneRowPerEntry() {
        let one = QuickPasteLayout.panelSize(entryCount: 1)
        let two = QuickPasteLayout.panelSize(entryCount: 2)
        let five = QuickPasteLayout.panelSize(entryCount: 5)

        XCTAssertEqual(one.height, Geometry.height(1), accuracy: 0.001)
        XCTAssertEqual(two.height - one.height, Geometry.rowHeight, accuracy: 0.001)
        XCTAssertEqual(five.height, Geometry.height(5), accuracy: 0.001)
        XCTAssertEqual(five.width, Geometry.width, accuracy: 0.001)
    }

    func testAnEmptyPanelIsAsTallAsAOneRowPanel() {
        // Nothing to point at, but the "history is empty" line still needs a row of space.
        XCTAssertEqual(
            QuickPasteLayout.panelSize(entryCount: 0).height,
            QuickPasteLayout.panelSize(entryCount: 1).height,
            accuracy: 0.001
        )
    }

    // MARK: - Hit testing: inside each row

    func testEveryRowIsHitAtItsOwnCentre() {
        let frame = panelFrame(entryCount: 5)

        for slot in 0..<5 {
            XCTAssertEqual(
                QuickPasteLayout.highlightedIndex(
                    mouse: Geometry.centreOfSlot(slot, in: frame),
                    panelFrame: frame,
                    entryCount: 5
                ),
                slot,
                "slot \(slot) should map to index \(slot)"
            )
        }
    }

    func testTheTopRowIsTheNewestEntry() {
        let frame = panelFrame(entryCount: 3)

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: Geometry.centreOfSlot(0, in: frame),
                panelFrame: frame,
                entryCount: 3
            ),
            0
        )
    }

    // MARK: - Hit testing: outside the panel

    func testAboveThePanelIsNothing() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.midX, y: frame.maxY + 1)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testBelowThePanelIsNothing() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.midX, y: frame.minY - 1)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testLeftOfThePanelIsNothing() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.minX - 1, y: Geometry.centreOfSlot(1, in: frame).y)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testRightOfThePanelIsNothing() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.maxX + 1, y: Geometry.centreOfSlot(1, in: frame).y)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testTheHeaderStripIsNotARow() {
        // Inside the panel, above the first row: the title, not something choosable.
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.midX, y: Geometry.rowsTop(frame) + 1)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testTheBottomPaddingIsNotARow() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.midX, y: frame.minY + 1)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3)
        )
    }

    func testAnEmptyPanelHasNothingToPointAt() {
        let frame = panelFrame(entryCount: 0)
        let mouse = CGPoint(x: frame.midX, y: Geometry.centreOfSlot(0, in: frame).y)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 0)
        )
    }

    // MARK: - Hit testing: boundaries

    func testTheLineBetweenTwoRowsBelongsToTheLowerRow() {
        let frame = panelFrame(entryCount: 3)
        let boundary = CGPoint(x: frame.midX, y: Geometry.rowsTop(frame) - Geometry.rowHeight)

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(mouse: boundary, panelFrame: frame, entryCount: 3),
            1
        )
    }

    func testOneHairAboveThatLineIsStillTheUpperRow() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(
            x: frame.midX,
            y: Geometry.rowsTop(frame) - Geometry.rowHeight + 0.001
        )

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3),
            0
        )
    }

    func testTheVeryTopEdgeOfTheFirstRowIsTheFirstRow() {
        let frame = panelFrame(entryCount: 3)
        let mouse = CGPoint(x: frame.midX, y: Geometry.rowsTop(frame))

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3),
            0
        )
    }

    func testTheVeryBottomEdgeOfTheLastRowIsTheLastRow() {
        let frame = panelFrame(entryCount: 3)
        let bottom = Geometry.rowsTop(frame) - 3 * Geometry.rowHeight
        let mouse = CGPoint(x: frame.midX, y: bottom)

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(mouse: mouse, panelFrame: frame, entryCount: 3),
            2
        )
    }

    func testTheLeftAndRightEdgesOfThePanelAreInside() {
        let frame = panelFrame(entryCount: 3)
        let y = Geometry.centreOfSlot(1, in: frame).y

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: frame.minX, y: y), panelFrame: frame, entryCount: 3
            ),
            1
        )
        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: frame.maxX, y: y), panelFrame: frame, entryCount: 3
            ),
            1
        )
    }

    // MARK: - Hit testing when the panel had to flip above the cursor

    func testFlippedPanelPutsTheNewestEntryInTheBottomRow() {
        let frame = panelFrame(entryCount: 3)

        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: Geometry.centreOfSlot(2, in: frame),
                panelFrame: frame,
                entryCount: 3,
                isFlipped: true
            ),
            0,
            "the row nearest the cursor is the newest entry"
        )
        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: Geometry.centreOfSlot(0, in: frame),
                panelFrame: frame,
                entryCount: 3,
                isFlipped: true
            ),
            2
        )
    }

    func testFlippingDoesNotChangeWhatCountsAsOutsideThePanel() {
        let frame = panelFrame(entryCount: 3)

        XCTAssertNil(
            QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: frame.midX, y: frame.maxY + 1),
                panelFrame: frame,
                entryCount: 3,
                isFlipped: true
            )
        )
    }

    // MARK: - Placement: the ordinary case

    func testPanelHangsUnderTheCursorWithAGap() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 700, y: 600)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )

        XCTAssertFalse(placement.isFlipped)
        XCTAssertEqual(placement.origin.y, cursor.y - Geometry.gap - size.height, accuracy: 0.001)
        XCTAssertEqual(placement.origin.x, cursor.x - Geometry.cursorInsetX, accuracy: 0.001)
    }

    func testTheNewestEntrySitsNearestTheCursorWhenHangingBelow() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 700, y: 600)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )
        let frame = CGRect(origin: placement.origin, size: size)

        // Walk straight down from the cursor: the first row met is the newest entry.
        let firstRowY = Geometry.rowsTop(frame) - 1
        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: cursor.x, y: firstRowY),
                panelFrame: frame,
                entryCount: 5,
                isFlipped: placement.isFlipped
            ),
            0
        )
    }

    // MARK: - Placement: clamped to the visible frame

    func testNearTheBottomEdgeThePanelFlipsAboveTheCursorInsteadOfBeingCutOff() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 700, y: 30)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )

        XCTAssertTrue(placement.isFlipped)
        XCTAssertGreaterThanOrEqual(placement.origin.y, screen.minY)
        XCTAssertLessThanOrEqual(placement.origin.y + size.height, screen.maxY)
        XCTAssertEqual(placement.origin.y, cursor.y + Geometry.gap, accuracy: 0.001)
    }

    func testAFlippedPanelStillPutsTheNewestEntryNearestTheCursor() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 700, y: 30)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )
        let frame = CGRect(origin: placement.origin, size: size)

        // Walk straight up from the cursor: the first row met is the newest entry.
        let bottomRowY = Geometry.rowsTop(frame) - 5 * Geometry.rowHeight + 1
        XCTAssertEqual(
            QuickPasteLayout.highlightedIndex(
                mouse: CGPoint(x: cursor.x, y: bottomRowY),
                panelFrame: frame,
                entryCount: 5,
                isFlipped: placement.isFlipped
            ),
            0
        )
    }

    func testNearTheRightEdgeThePanelIsPushedLeftToStayWhole() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 1435, y: 600)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )

        XCTAssertEqual(placement.origin.x, screen.maxX - size.width, accuracy: 0.001)
        XCTAssertLessThanOrEqual(placement.origin.x + size.width, screen.maxX)
    }

    func testNearTheLeftEdgeThePanelIsPushedRightToStayWhole() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 2, y: 600)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )

        XCTAssertEqual(placement.origin.x, screen.minX, accuracy: 0.001)
    }

    func testNearTheTopEdgeThePanelStillHangsBelowTheCursor() {
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursor = CGPoint(x: 700, y: 898)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )

        XCTAssertFalse(placement.isFlipped)
        XCTAssertLessThanOrEqual(placement.origin.y + size.height, screen.maxY)
    }

    func testASecondaryDisplayVisibleFrameIsRespectedRatherThanAssumedToStartAtZero() {
        // A display to the left of, and below, the main one: negative origin, and a menu
        // bar inset the panel must not stray into.
        let size = QuickPasteLayout.panelSize(entryCount: 5)
        let screen = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        let cursor = CGPoint(x: -1910, y: -380)

        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: screen
        )
        let frame = CGRect(origin: placement.origin, size: size)

        XCTAssertTrue(screen.contains(frame), "\(frame) should sit inside \(screen)")
    }

    func testAPanelIsNeverPushedOffTheLeftEdgeByAScreenNarrowerThanItself() {
        // Degenerate, but the naive min(max(...)) form silently returns a negative x here.
        let size = CGSize(width: 400, height: 200)
        let screen = CGRect(x: 0, y: 0, width: 300, height: 900)

        let placement = QuickPasteLayout.placement(
            cursor: CGPoint(x: 150, y: 600), size: size, visibleFrame: screen
        )

        XCTAssertEqual(placement.origin.x, screen.minX, accuracy: 0.001)
    }
}
