import CoreGraphics
import Foundation
import HotkeyEngine

/// Which row of the open panel is chosen, and which input chose it.
///
/// The popup has two ways in — the pointer and the arrow keys — and they disagree by
/// nature: the highlight is resampled from the mouse sixty times a second whether the
/// mouse moved or not, so without an owner the next sample would silently undo every
/// arrow press. The rule is that whichever input moved *last* owns the selection. An
/// arrow takes ownership from the pointer, and only a pointer that actually changed
/// position takes it back — a still mouse being read again is not a move.
///
/// The same rule covers the moment the panel appears. Near the bottom of the screen the
/// panel is shifted up and opens *over* the pointer (`QuickPasteLayout.placement`), so a
/// row is under it that nobody pointed at. A pointer therefore selects nothing until it
/// has moved: the reading taken at reveal is only where it was. Releasing without moving
/// cancels, exactly as it does when the panel hangs below the cursor and the pointer is
/// on no row at all.
///
/// Screen order and array order are the same thing (#211). Entry 0 is the newest and is
/// always the top row, so the row below entry 2 is entry 3 and "down" is one step towards
/// older entries. Both directions wrap, so a held arrow cycles the list forever.
///
/// Pure, like the rest of this package: no window, no timer, no `NSEvent`. The controller
/// feeds it a mouse position and a hit-tested index and asks what is selected.
public struct QuickPasteSelection: Equatable, Sendable {
    /// Which input last moved, and therefore whose answer the highlight shows.
    public enum Owner: Equatable, Sendable {
        case pointer
        case keyboard
    }

    /// How many rows the open panel is showing.
    public let entryCount: Int

    public private(set) var owner: Owner = .pointer
    /// Index into the entries array, newest first — the same index
    /// `QuickPasteLayout.highlightedIndex` returns. `nil` is a real answer: nothing is
    /// selected, and releasing now cancels.
    public private(set) var index: Int?

    /// Where the pointer was the last time it was read. `nil` until the first reading,
    /// which is a baseline rather than evidence of a move.
    private var lastPointer: CGPoint?

    public init(entryCount: Int) {
        self.entryCount = entryCount
    }

    // MARK: - The arithmetic

    /// The row one step from `current` in the direction of the arrow, wrapping at both
    /// ends. `nil` in, or an index outside the list, means nothing is selected yet: down
    /// then starts at the top row, the newest entry, and up at the bottom row, the oldest.
    public static func moved(
        from current: Int?,
        direction: HoldToRevealArrowDirection,
        entryCount: Int
    ) -> Int? {
        guard entryCount > 0 else { return nil }

        guard let current, current >= 0, current < entryCount else {
            // The first press picks where to start: "down" enters the list from its top,
            // "up" from its bottom.
            return direction == .down ? 0 : entryCount - 1
        }

        // One row down the screen is one step forward through the array: an older entry.
        let step = direction == .down ? 1 : -1
        return ((current + step) % entryCount + entryCount) % entryCount
    }

    // MARK: - Ownership

    /// Records a reading of the pointer and the row it is over.
    ///
    /// A reading at the position of the previous one changes nothing: the highlight timer
    /// samples a motionless mouse many times a second, and treating that as a move would
    /// wipe out the keyboard's choice within milliseconds. Anything else is a real move
    /// and hands the selection back to the pointer, including a move off the rows
    /// entirely — that is what keeps "release over nothing" a cancel.
    ///
    /// The first reading is never a move, whatever row it is over: the panel may have
    /// opened under the pointer. It selects nothing and takes nothing from the keyboard.
    @discardableResult
    public mutating func pointerSampled(at location: CGPoint, hitting hit: Int?) -> Int? {
        defer { lastPointer = location }

        guard let last = lastPointer, location != last else {
            // The first reading of this gesture, or the same place read again: no move,
            // so nothing changes. `hit` is not looked at — the panel does not move while
            // it is open, so a pointer that stayed put is over what it was over before,
            // and before its first move that is a row it never pointed at.
            return index
        }

        owner = .pointer
        index = hit
        return index
    }

    /// Moves the selection one row the way the arrow points, and hands it to the keyboard.
    @discardableResult
    public mutating func arrowPressed(_ direction: HoldToRevealArrowDirection) -> Int? {
        owner = .keyboard
        index = Self.moved(from: index, direction: direction, entryCount: entryCount)
        return index
    }
}
