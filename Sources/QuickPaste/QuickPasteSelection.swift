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
/// The arithmetic is in screen terms, not array terms. Entry 0 is the newest, and the
/// layout always puts it against the cursor: the top row when the panel hangs below,
/// the bottom row when it had to open above (`isFlipped`, see `QuickPasteLayout`). So in
/// a flipped panel the row visually *below* entry 2 is entry 1, and "down" walks the
/// array backwards. Both directions wrap, so a held arrow cycles the list forever.
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
    /// Whether those rows are drawn bottom-up.
    public let isFlipped: Bool

    public private(set) var owner: Owner = .pointer
    /// Index into the entries array, newest first — the same index
    /// `QuickPasteLayout.highlightedIndex` returns. `nil` is a real answer: nothing is
    /// selected, and releasing now cancels.
    public private(set) var index: Int?

    /// Where the pointer was the last time it was read. `nil` until the first reading,
    /// which is a baseline rather than evidence of a move.
    private var lastPointer: CGPoint?

    public init(entryCount: Int, isFlipped: Bool) {
        self.entryCount = entryCount
        self.isFlipped = isFlipped
    }

    // MARK: - The arithmetic

    /// The row one step from `current` in the direction seen on screen, wrapping at both
    /// ends. `nil` in, or an index outside the list, means nothing is selected yet: down
    /// then starts at the entry nearest the cursor and up at the far one.
    public static func moved(
        from current: Int?,
        direction: HoldToRevealArrowDirection,
        entryCount: Int,
        isFlipped: Bool
    ) -> Int? {
        guard entryCount > 0 else { return nil }

        guard let current, current >= 0, current < entryCount else {
            // The first press picks where to start. Entry 0 is the one against the
            // cursor in either layout, so "down" reaches for the nearest row and "up"
            // for the far end of the list.
            return direction == .down ? 0 : entryCount - 1
        }

        // One row down the screen is one step forward through the array — unless the
        // rows are drawn bottom-up, in which case it is one step back.
        let screenStep = direction == .down ? 1 : -1
        let arrayStep = isFlipped ? -screenStep : screenStep
        return ((current + arrayStep) % entryCount + entryCount) % entryCount
    }

    // MARK: - Ownership

    /// Records a reading of the pointer and the row it is over.
    ///
    /// A reading at the position of the previous one changes nothing: the highlight timer
    /// samples a motionless mouse many times a second, and treating that as a move would
    /// wipe out the keyboard's choice within milliseconds. Anything else is a real move
    /// and hands the selection back to the pointer, including a move off the rows
    /// entirely — that is what keeps "release over nothing" a cancel.
    @discardableResult
    public mutating func pointerSampled(at location: CGPoint, hitting hit: Int?) -> Int? {
        defer { lastPointer = location }

        guard let last = lastPointer else {
            // First reading of this gesture. It says where the pointer is, not that it
            // moved, so it does not take anything away from the keyboard.
            if owner == .pointer { index = hit }
            return index
        }

        guard location != last else {
            if owner == .pointer { index = hit }
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
        index = Self.moved(
            from: index,
            direction: direction,
            entryCount: entryCount,
            isFlipped: isFlipped
        )
        return index
    }
}
