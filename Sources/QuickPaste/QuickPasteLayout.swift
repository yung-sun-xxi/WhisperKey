import CoreGraphics
import Foundation

/// Where the panel sits relative to the cursor, and therefore which end of the list is
/// nearest it.
public struct QuickPastePlacement: Equatable, Sendable {
    /// Bottom-left corner of the panel, in screen coordinates.
    public let origin: CGPoint
    /// `true` when the panel had to go *above* the cursor because there was no room
    /// below. Rows are then rendered bottom-up, so the newest entry is still the one
    /// next to the cursor.
    public let isFlipped: Bool

    public init(origin: CGPoint, isFlipped: Bool) {
        self.origin = origin
        self.isFlipped = isFlipped
    }
}

/// The geometry of the quick-paste panel: how big it is, where it goes, and which row a
/// point falls in.
///
/// All of it is a pure function of the entry count and the screen, with no window, no
/// view and no mouse involved — which is the only reason any of it is provable. The panel
/// takes no mouse events at all (`ignoresMouseEvents = true`), so there is no hit-testing
/// anywhere else to disagree with: the window is sized from `panelSize`, placed at
/// `placement`, and the highlighted row is `highlightedIndex` of wherever the pointer is.
///
/// Screen coordinates throughout, so y grows *upwards* and "under the cursor" is a
/// *smaller* y.
public enum QuickPasteLayout {
    // MARK: - The constants the view is built from

    public static let contentWidth: CGFloat = 320
    public static let horizontalPadding: CGFloat = 4
    public static let verticalPadding: CGFloat = 9
    public static let headerHeight: CGFloat = 14
    public static let headerBottomSpacing: CGFloat = 4
    /// Rows are contiguous — no spacing between them — so that there is no dead strip in
    /// which a release would mean nothing. Separation is drawn inside the row instead.
    public static let rowHeight: CGFloat = 26
    /// Distance between the cursor and the near edge of the panel.
    public static let cursorGap: CGFloat = 10
    /// How far left of the cursor the panel's leading edge sits, so the pointer starts
    /// just inside the panel's width rather than on its corner.
    public static let cursorInsetX: CGFloat = 16
    /// Characters of an entry a row shows. Generous rather than tight: the row itself is
    /// one line with tail truncation, so this is the point at which the *text* is cut,
    /// and the row cuts again if even this does not fit the width. A short budget would
    /// throw away characters the row had room for.
    public static let previewLength = 80

    /// Height of everything above the first row: the outer padding and the header.
    static var headerBand: CGFloat { verticalPadding + headerHeight + headerBottomSpacing }

    // MARK: - Size

    /// An empty history still shows one row's worth of space, for the "history is empty"
    /// line, so the panel never collapses to a sliver.
    public static func panelSize(entryCount: Int) -> CGSize {
        let rows = CGFloat(max(entryCount, 1))
        return CGSize(
            width: contentWidth,
            height: verticalPadding * 2 + headerHeight + headerBottomSpacing + rows * rowHeight
        )
    }

    // MARK: - Placement

    /// Where a panel of `size` goes for a cursor at `cursor` on a screen whose usable
    /// area is `visibleFrame`.
    ///
    /// Hangs below the cursor by preference, which puts the newest entry — the top row —
    /// closest to the pointer. When the cursor is too near the bottom of the screen for
    /// the whole panel to fit below it, the panel goes above the cursor instead of being
    /// clamped into it, and the caller renders the rows bottom-up so the newest entry is
    /// still the nearest one. Clamping without flipping would have left the *oldest*
    /// entry against the cursor.
    public static func placement(
        cursor: CGPoint,
        size: CGSize,
        visibleFrame: CGRect
    ) -> QuickPastePlacement {
        let x = clamp(
            cursor.x - cursorInsetX,
            lower: visibleFrame.minX,
            upper: visibleFrame.maxX - size.width
        )

        let below = cursor.y - cursorGap - size.height
        if below >= visibleFrame.minY {
            let y = clamp(below, lower: visibleFrame.minY, upper: visibleFrame.maxY - size.height)
            return QuickPastePlacement(origin: CGPoint(x: x, y: y), isFlipped: false)
        }

        let above = cursor.y + cursorGap
        let y = clamp(above, lower: visibleFrame.minY, upper: visibleFrame.maxY - size.height)
        return QuickPastePlacement(origin: CGPoint(x: x, y: y), isFlipped: true)
    }

    /// Clamps to `lower...upper`, and to `lower` when the range is empty — which happens
    /// when the panel is wider or taller than the screen. Keeping the leading and bottom
    /// edges visible is the better half to lose.
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }

    // MARK: - Hit testing

    /// Which entry a pointer at `mouse` is over, or `nil` for none — outside the panel,
    /// in the header, in the padding, or over an empty history.
    ///
    /// `nil` is what makes releasing over nothing a cancel, so it is a real answer rather
    /// than a failure to find one.
    ///
    /// Boundaries: the top edge of the first row and the bottom edge of the last row are
    /// both inside; the line between two rows belongs to the *lower* of the two.
    ///
    /// The index returned is into the entries array, newest first. When `isFlipped` the
    /// rows are drawn bottom-up, so the bottom visual row is entry 0.
    public static func highlightedIndex(
        mouse: CGPoint,
        panelFrame: CGRect,
        entryCount: Int,
        isFlipped: Bool = false
    ) -> Int? {
        guard entryCount > 0 else { return nil }
        guard mouse.x >= panelFrame.minX, mouse.x <= panelFrame.maxX else { return nil }

        let rowsTop = panelFrame.maxY - headerBand
        let rowsBottom = rowsTop - CGFloat(entryCount) * rowHeight
        guard mouse.y <= rowsTop, mouse.y >= rowsBottom else { return nil }

        // Counted from the top of the list. The floor puts a shared boundary in the lower
        // row; the min catches the bottom edge, where the division lands exactly on
        // `entryCount`.
        let slot = min(Int((rowsTop - mouse.y) / rowHeight), entryCount - 1)
        return isFlipped ? entryCount - 1 - slot : slot
    }
}
