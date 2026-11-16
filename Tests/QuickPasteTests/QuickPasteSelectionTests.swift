import CoreGraphics
import HotkeyEngine
import XCTest
@testable import QuickPaste

/// Which row the arrow keys land on, and which input owns the highlight.
///
/// Index arithmetic against a list drawn top-down, newest first: entry `i` is row `i`
/// from the top (#211), so "the row below" is the next index and nothing here needs a
/// second layout to check against.
final class QuickPasteSelectionTests: XCTestCase {

    // MARK: - The first press picks a starting row

    func testFirstDownPressSelectsTheNewestEntry() {
        // Entry 0 is the newest and the top row: down enters the list from the top.
        XCTAssertEqual(
            QuickPasteSelection.moved(from: nil, direction: .down, entryCount: 5),
            0
        )
    }

    func testFirstUpPressSelectsTheOldestEntry() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: nil, direction: .up, entryCount: 5),
            4
        )
    }

    func testAnOutOfRangeSelectionIsTreatedAsNoSelection() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 9, direction: .down, entryCount: 3),
            0
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: -1, direction: .up, entryCount: 3),
            2
        )
    }

    func testAnEmptyListHasNothingToSelect() {
        XCTAssertNil(
            QuickPasteSelection.moved(from: nil, direction: .down, entryCount: 0)
        )
        XCTAssertNil(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 0)
        )
    }

    // MARK: - One row per press: down is older, up is newer

    func testDownIsAlwaysTheNextOlderEntry() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .down, entryCount: 4),
            1
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 2, direction: .down, entryCount: 4),
            3
        )
    }

    func testUpIsAlwaysTheNextNewerEntry() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 3, direction: .up, entryCount: 4),
            2
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 1, direction: .up, entryCount: 4),
            0
        )
    }

    func testUpAndDownAreExactInverses() {
        for start in 0..<6 {
            let down = QuickPasteSelection.moved(from: start, direction: .down, entryCount: 6)
            let back = QuickPasteSelection.moved(from: down, direction: .up, entryCount: 6)
            XCTAssertEqual(back, start, "start=\(start)")
        }
    }

    // MARK: - Wrapping, in both directions

    func testDownFromTheLastRowWrapsToTheFirst() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 3, direction: .down, entryCount: 4),
            0
        )
    }

    func testUpFromTheFirstRowWrapsToTheLast() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 4),
            3
        )
    }

    func testHoldingAnArrowCyclesTheListForever() {
        var index: Int? = nil
        var seen: [Int] = []
        for _ in 0..<11 {
            index = QuickPasteSelection.moved(from: index, direction: .down, entryCount: 4)
            seen.append(index ?? -1)
        }
        XCTAssertEqual(seen, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2])
    }

    func testHoldingUpCyclesTheOtherWay() {
        var index: Int? = nil
        var seen: [Int] = []
        for _ in 0..<6 {
            index = QuickPasteSelection.moved(from: index, direction: .up, entryCount: 4)
            seen.append(index ?? -1)
        }
        XCTAssertEqual(seen, [3, 2, 1, 0, 3, 2])
    }

    func testASingleEntryStaysSelectedWhicheverArrowIsPressed() {
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .down, entryCount: 1),
            0
        )
        XCTAssertEqual(
            QuickPasteSelection.moved(from: 0, direction: .up, entryCount: 1),
            0
        )
    }

    // MARK: - Whichever input moved last owns the highlight

    private func selection(entryCount: Int = 4) -> QuickPasteSelection {
        QuickPasteSelection(entryCount: entryCount)
    }

    /// A selection whose pointer has been seen once, at `start`, over nothing: the state
    /// right after an ordinary reveal, with the panel hanging below the cursor.
    private func revealedSelection(
        entryCount: Int = 4,
        pointerAt start: CGPoint = CGPoint(x: 10, y: 0)
    ) -> QuickPasteSelection {
        var selection = self.selection(entryCount: entryCount)
        selection.pointerSampled(at: start, hitting: nil)
        return selection
    }

    func testThePointerOwnsTheHighlightUntilAnArrowIsPressed() {
        var selection = revealedSelection()

        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        XCTAssertEqual(selection.owner, .pointer)
        XCTAssertEqual(selection.index, 2)
    }

    func testAnArrowTakesTheHighlightFromThePointer() {
        var selection = revealedSelection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)

        selection.arrowPressed(.down)

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 3)
    }

    func testAStillPointerDoesNotTakeTheHighlightBack() {
        // The highlight is resampled sixty times a second whether the mouse moved or not.
        var selection = revealedSelection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        selection.arrowPressed(.down)

        for _ in 0..<60 {
            selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        }

        XCTAssertEqual(selection.owner, .keyboard)
        XCTAssertEqual(selection.index, 3)
    }

    func testMovingThePointerTakesTheHighlightBack() {
        var selection = revealedSelection()
        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: 2)
        selection.arrowPressed(.down)

        selection.pointerSampled(at: CGPoint(x: 10, y: 11), hitting: 1)

        XCTAssertEqual(selection.owner, .pointer)
        XCTAssertEqual(selection.index, 1)
    }

    func testMovingThePointerOffThePanelClearsTheKeyboardsChoice() {
        // Off the rows is a real answer — it is what makes releasing over nothing a cancel.
        var selection = revealedSelection()
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
        var selection = revealedSelection()
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

    // MARK: - A panel that opens over a pointer that has not moved (#211)

    func testOpeningOverAStillPointerSelectsNothing() {
        // Near the bottom of the screen the panel is shifted up and covers the pointer.
        // The row that happens to be under it was not pointed at.
        var selection = self.selection()

        selection.pointerSampled(at: CGPoint(x: 700, y: 30), hitting: 3)

        XCTAssertNil(selection.index)
        XCTAssertEqual(selection.owner, .pointer)
    }

    func testAStillPointerOverARowStaysUnselectedHoweverOftenItIsRead() {
        // The reveal's reading, a second of the highlight timer, and the release's.
        var selection = self.selection()

        for _ in 0..<62 {
            selection.pointerSampled(at: CGPoint(x: 700, y: 30), hitting: 3)
        }

        XCTAssertNil(selection.index, "releasing now must cancel, not paste entry 3")
    }

    func testTheFirstRealMoveSelectsTheRowUnderThePointer() {
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 700, y: 30), hitting: 3)

        selection.pointerSampled(at: CGPoint(x: 700, y: 31), hitting: 3)

        XCTAssertEqual(selection.index, 3)
        XCTAssertEqual(selection.owner, .pointer)
    }

    func testAPointerThatMovedAndStoppedKeepsItsRow() {
        // Still only counts as "not pointed at" before the first move.
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 700, y: 30), hitting: 3)
        selection.pointerSampled(at: CGPoint(x: 700, y: 80), hitting: 2)

        for _ in 0..<60 {
            selection.pointerSampled(at: CGPoint(x: 700, y: 80), hitting: 2)
        }

        XCTAssertEqual(selection.index, 2)
    }

    func testAnArrowOverAStillPointerStartsFromTheNewestEntry() {
        // Nothing was selected, so down starts at the top row, not below the row the
        // pointer happens to rest on.
        var selection = self.selection()
        selection.pointerSampled(at: CGPoint(x: 700, y: 30), hitting: 3)

        selection.arrowPressed(.down)

        XCTAssertEqual(selection.index, 0)
        XCTAssertEqual(selection.owner, .keyboard)
    }

    /// The whole reveal near the bottom edge, as the controller runs it: place the panel,
    /// hit-test the pointer where it already was, read it at reveal and again at release.
    func testReleasingWithoutMovingOverAShiftedPanelCancels() {
        let metrics = QuickPasteMetrics(
            width: 328, edgeWidth: 1, headerHeight: 36, separatorHeight: 1, rowHeight: 34, rowInset: 8
        )
        let size = QuickPasteLayout.panelSize(entryCount: 5, metrics: metrics)
        let cursor = CGPoint(x: 700, y: 30)
        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let frame = CGRect(origin: placement.origin, size: size)
        let hit = QuickPasteLayout.highlightedIndex(
            mouse: cursor, panelFrame: frame, entryCount: 5, metrics: metrics
        )
        XCTAssertNotNil(hit, "the panel should have opened over the pointer")

        var selection = self.selection(entryCount: 5)
        selection.pointerSampled(at: cursor, hitting: hit)
        let committed = selection.pointerSampled(at: cursor, hitting: hit)

        XCTAssertNil(committed, "a release without a move pasted entry \(String(describing: committed))")
    }

    /// The ordinary case, unchanged: the panel hangs below the cursor, the pointer is not
    /// on it, and a release without a move cancels.
    func testReleasingWithoutMovingUnderAPanelBelowTheCursorCancels() {
        let metrics = QuickPasteMetrics(
            width: 328, edgeWidth: 1, headerHeight: 36, separatorHeight: 1, rowHeight: 34, rowInset: 8
        )
        let size = QuickPasteLayout.panelSize(entryCount: 5, metrics: metrics)
        let cursor = CGPoint(x: 700, y: 600)
        let placement = QuickPasteLayout.placement(
            cursor: cursor, size: size, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let frame = CGRect(origin: placement.origin, size: size)
        let hit = QuickPasteLayout.highlightedIndex(
            mouse: cursor, panelFrame: frame, entryCount: 5, metrics: metrics
        )
        XCTAssertNil(hit, "the pointer starts above the panel, on nothing")

        var selection = self.selection(entryCount: 5)
        selection.pointerSampled(at: cursor, hitting: hit)

        XCTAssertNil(selection.pointerSampled(at: cursor, hitting: hit))
    }

    func testAnEmptyPanelSelectsNothingWhicheverInputMoves() {
        var selection = self.selection(entryCount: 0)

        selection.arrowPressed(.down)
        XCTAssertNil(selection.index)

        selection.pointerSampled(at: CGPoint(x: 10, y: 10), hitting: nil)
        XCTAssertNil(selection.index)
    }
}
