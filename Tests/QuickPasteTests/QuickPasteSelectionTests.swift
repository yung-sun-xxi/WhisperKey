import CoreGraphics
import HotkeyEngine
import XCTest
@testable import QuickPaste

/// Which row the arrow keys land on, and which input owns the highlight.
///
/// Everything here is index arithmetic against a list whose rows may be drawn top-down or
/// bottom-up. The visual position of entry `i` is spelled out below rather than read back
/// from the implementation, because "the row visually below" is the whole claim.
private func slot(ofEntry index: Int, entryCount: Int, isFlipped: Bool) -> Int {
    isFlipped ? entryCount - 1 - index : index
}

final class QuickPasteSelectionTests: XCTestCase {

    // MARK: - The first press picks a starting row

    func testFirstDownPressSelectsTheEntryNearestTheCursor() {
        // Entry 0 is the newest, and the layout always puts it against the pointer —
        // top row when the panel hangs below, bottom row when it opens above.
        for isFlipped in [false, true] {
            XCTAssertEqual(
                QuickPasteSelection.moved(from: nil, direction: .down,
                                          entryCount: 5, isFlipped: isFlipped),
                0,
                "isFlipped=\(isFlipped)"
            )
        }
    }

    func testFirstUpPressSelectsTheFarEntry() {
        for isFlipped in [false, true] {
            XCTAssertEqual(
                QuickPasteSelection.moved(from: nil, direction: .up,
                                          entryCount: 5, isFlipped: isFlipped),
                4,
                "isFlipped=\(isFlipped)"
            )
        }
    }

    func testAnOutOfRangeSelectionIsTreatedAsNoSelection() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 9, direction: .down, entryCount: 3, isFlipped: false),
            0
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: -1, direction: .up, entryCount: 3, isFlipped: false),
            2
        )
    }

    func testAnEmptyListHasNothingToSelect() {
        XCTAssertNil(
            QuickPasteSelection.moved(from: nil, direction: .down, entryCount: 0, isFlipped: false)
        )
        XCTAssertNil(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 0, isFlipped: true)
        )
    }

    // MARK: - One row per press, in the direction seen on screen

    func testDownWalksTheListDownwardsWhenThePanelHangsBelowTheCursor() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .down, entryCount: 4, isFlipped: false),
            1
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 2, direction: .down, entryCount: 4, isFlipped: false),
            3
        )
    }

    func testDownWalksTheOtherWayThroughTheArrayWhenThePanelOpenedAboveTheCursor() {
        // Rows are drawn bottom-up, so the row visually below entry 2 is entry 1.
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 2, direction: .down, entryCount: 4, isFlipped: true),
            1
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 3, direction: .up, entryCount: 4, isFlipped: true),
            0
        )
    }

    func testUpAndDownAreExactInverses() {
        for isFlipped in [false, true] {
            for start in 0..<6 {
                let down = QuickPasteSelection.moved(from: start, direction: .down,
                                                     entryCount: 6, isFlipped: isFlipped)
                let back = QuickPasteSelection.moved(from: down, direction: .up,
                                                     entryCount: 6, isFlipped: isFlipped)
                XCTAssertEqual(back, start, "isFlipped=\(isFlipped) start=\(start)")
            }
        }
    }

    // MARK: - Wrapping, in both directions

    func testDownFromTheLastVisibleRowWrapsToTheFirst() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 3, direction: .down, entryCount: 4, isFlipped: false),
            0
        )
        // Flipped: the visually last row is entry 0, and below it is entry 3.
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .down, entryCount: 4, isFlipped: true),
            3
        )
    }

    func testUpFromTheFirstVisibleRowWrapsToTheLast() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 4, isFlipped: false),
            3
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 3, direction: .up, entryCount: 4, isFlipped: true),
            0
        )
    }

    func testHoldingAnArrowCyclesTheListForever() {
        var index: Int? = nil
        var seen: [Int] = []
        for _ in 0..<11 {
            index = QuickPasteSelection.moved(from: index, direction: .down,
                                              entryCount: 4, isFlipped: false)
            seen.append(index ?? -1)
        }
        XCTAssertEqual(seen, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2])
    }

    func testASingleEntryStaysSelectedWhicheverArrowIsPressed() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .down, entryCount: 1, isFlipped: false),
            0
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 1, isFlipped: true),
            0
        )
    }

    // MARK: - The same visual motion in a flipped panel as in an unflipped one

    func testAfterTheFirstPressTheHighlightWalksDownTheScreenInBothLayouts() {
        let count = 4

        func visualWalk(isFlipped: Bool, direction: HoldToRevealArrowDirection) -> [Int] {
            var index: Int? = nil
            var slots: [Int] = []
            for _ in 0..<(count + 1) {
                index = QuickPasteSelection.moved(from: index, direction: direction,
                                                  entryCount: count, isFlipped: isFlipped)
                slots.append(slot(ofEntry: index ?? -1, entryCount: count, isFlipped: isFlipped))
            }
            // Drop the first press, which only chooses where to start.
            return Array(slots.dropFirst())
        }

        for isFlipped in [false, true] {
            let down = visualWalk(isFlipped: isFlipped, direction: .down)
            let steps = zip(down, down.dropFirst()).map { ($1 - $0 + count) % count }
            XCTAssertEqual(steps, Array(repeating: 1, count: steps.count),
                           "down must move one row down the screen, isFlipped=\(isFlipped)")

            let up = visualWalk(isFlipped: isFlipped, direction: .up)
            let upSteps = zip(up, up.dropFirst()).map { ($1 - $0 + count) % count }
            XCTAssertEqual(upSteps, Array(repeating: count - 1, count: upSteps.count),
                           "up must move one row up the screen, isFlipped=\(isFlipped)")
        }
    }

    func testTheFirstDownPressLandsOnTheRowNextToTheCursorInBothLayouts() {
        // Below the cursor the nearest row is the top one; above it, the bottom one.
        let flat = QuickPasteSelection.moved(from: nil, direction: .down,
                                             entryCount: 4, isFlipped: false)
        XCTAssertEqual(slot(ofEntry: flat!, entryCount: 4, isFlipped: false), 0)

        let flipped = QuickPasteSelection.moved(from: nil, direction: .down,
                                                entryCount: 4, isFlipped: true)
        XCTAssertEqual(slot(ofEntry: flipped!, entryCount: 4, isFlipped: true), 3)
    }

    // MARK: - Whichever input moved last owns the highlight

    private func selection(entryCount: Int = 4, isFlipped: Bool = false) -> QuickPasteSelection {
        QuickPasteSelection(entryCount: entryCount, isFlipped: isFlipped)
    }

    func testThePointerOwnsTheHighlightUntilAnArrowIsPressed() {
        var selection = self.selection()

        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        XCTAssertEqual(selection.owner, .pointer)
        XCTAssertEqual(selection.index, 2)
    }

    func testAnArrowTakesTheHighlightFromThePointer() {
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)

        selection.arrowPressed(.down)

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 3)
    }

    func testAStillPointerDoesNotTakeTheHighlightBack() {
        // The highlight is resampled sixty times a second whether the mouse moved or not.
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        selection.arrowPressed(.down)

        for _ in 0..<60 {
            selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        }

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 3)
    }

    func testMovingThePointerTakesTheHighlightBack() {
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        selection.arrowPressed(.down)

        selection.pointerSampled(at: CGPoint(x: 10, y: 11), hitting: 1)

        XCTAssertEqual(selection.owner, .pointer)
        XCTAssertEqual(selection.index, 1)
    }

    func testMovingThePointerOffThePanelClearsTheKeyboardsChoice() {
        // Off the rows is a real answer — it is what makes releasing over nothing a cancel.
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        selection.arrowPressed(.down)

        selection.pointerSampled(at: CGPoint(x: 900, y: 900), hitting: nil)

        XCTAssertEqual(selection.owner, .pointer)
        XCTAssertNil(selection.index)
    }

    func testAPointerThatHasNeverBeenSeenDoesNotStealOnItsFirstReading() {
        // The first reading establishes where the pointer is; it is not evidence that it
        // moved, so a panel steered by the keyboard before the first sample keeps its row.
        var selection = self.selection()
        selection.arrowPressed(.down)

        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 0)
    }

    func testAnArrowAfterAMouseMoveContinuesFromWhereThePointerLeftOff() {
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 0)
        selection.arrowPressed(.down)
        selection.pointerSampled(at: CGPoint(x: 10, y: 40), hitting: 2)

        selection.arrowPressed(.down)

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 3)
    }

    func testTheFirstArrowWithoutAnyPointerSampleStartsFromNothing() {
        var selection = self.selection()

        selection.arrowPressed(.up)

        XCTAssertEqual(selection.index, 3)
    }

    func testAPointerSampleBeforeAnyArrowStillCountsAsTheStartingPoint() {
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: nil)

        selection.arrowPressed(.down)

        XCTAssertEqual(selection.index, 0)
    }

    func testAnEmptyPanelSelectsNothingWhicheverInputMoves() {
        var selection = self.selection(entryCount: 0)

        selection.arrowPressed(.down)
        XCTAssertNil(selection.index)

        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: nil)
        XCTAssertNil(selection.index)
    }
}
