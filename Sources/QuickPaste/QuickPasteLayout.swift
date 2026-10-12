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

/// The sizes the panel is drawn at and chosen from: one value, built from the theme's
/// tokens by `ThemeKit` (`ThemeTokens.quickPasteMetrics`), read once per reveal, and
/// handed both to the hit test and to the view. Drawing and choosing therefore cannot
/// disagree about where a row is.
///
/// Top down: the shell's edge, a header bar `headerHeight` tall holding "Clipboard", a
/// separator `separatorHeight` tall, `rowInset` above the first row, the rows back to
/// back at `rowHeight` each, `rowInset` under the last row, and the edge again. The rows
/// are also inset `edgeWidth + rowInset` from the left and right; that changes where
/// they are drawn, not which one a pointer is in — the full width of the panel counts,
/// as it always has.
///
/// The numbers live in `ThemeKit`, not here, because this module cannot see the tokens:
/// `ThemeKit` depends on `SettingsStore`, which depends on this module.
public struct QuickPasteMetrics: Equatable, Sendable {
    /// The panel's width, its edges included.
    public var width: CGFloat
    /// The shell's edge, drawn inside the panel on every side. The content keeps clear
    /// of it, so the edge never covers the header bar or a row.
    public var edgeWidth: CGFloat
    /// The header bar above the rows.
    public var headerHeight: CGFloat
    /// The line under the header bar.
    public var separatorHeight: CGFloat
    /// Rows are contiguous — no spacing between them — so that there is no dead strip in
    /// which a release would mean nothing. Separation is drawn inside the row instead.
    public var rowHeight: CGFloat
    /// Between the rows and the separator above them, and between the rows and the
    /// panel's edges on the other three sides.
    public var rowInset: CGFloat

    public init(
        width: CGFloat,
        edgeWidth: CGFloat,
        headerHeight: CGFloat,
        separatorHeight: CGFloat,
        rowHeight: CGFloat,
        rowInset: CGFloat
    ) {
        self.width = width
        self.edgeWidth = edgeWidth
        self.headerHeight = headerHeight
        self.separatorHeight = separatorHeight
        self.rowHeight = rowHeight
        self.rowInset = rowInset
    }

    /// From the panel's top to the first row: edge, header bar, separator, inset.
    public var rowsTopOffset: CGFloat {
        edgeWidth + headerHeight + separatorHeight + rowInset
    }

    /// From the last row to the panel's bottom: inset, edge.
    public var rowsBottomOffset: CGFloat {
        rowInset + edgeWidth
    }
}

/// The geometry of the quick-paste panel: how big it is, where it goes, and which row a
/// point falls in.
///
/// All of it is a pure function of the entry count, the screen and the metrics, with no
/// window, no view and no mouse involved — which is the only reason any of it is
/// provable. The panel takes no mouse events at all (`ignoresMouseEvents = true`), so
/// there is no hit-testing anywhere else to disagree with: the window is sized from
/// `panelSize`, placed at `placement`, and the highlighted row is `highlightedIndex` of
/// wherever the pointer is, all with the same `QuickPasteMetrics`.
///
/// Screen coordinates throughout, so y grows *upwards* and "under the cursor" is a
/// *smaller* y.
public enum QuickPasteLayout {
    // MARK: - Behaviour, not look

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

    // MARK: - Size

    /// An empty history still shows one row's worth of space, for the "history is empty"
    /// line, so the panel never collapses to a sliver.
    public static func panelSize(entryCount: Int, metrics: QuickPasteMetrics) -> CGSize {
        let rows = CGFloat(max(entryCount, 1))
        return CGSize(
            width: metrics.width,
            height: metrics.rowsTopOffset + rows * metrics.rowHeight + metrics.rowsBottomOffset
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
    /// in the header bar or the inset above the first row, in the inset under the last
    /// row, or over an empty history.
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
        isFlipped: Bool = false,
        metrics: QuickPasteMetrics
    ) -> Int? {
        guard entryCount > 0 else { return nil }
        guard mouse.x >= panelFrame.minX, mouse.x <= panelFrame.maxX else { return nil }

        let rowsTop = panelFrame.maxY - metrics.rowsTopOffset
        let rowsBottom = rowsTop - CGFloat(entryCount) * metrics.rowHeight
        guard mouse.y <= rowsTop, mouse.y >= rowsBottom else { return nil }

        // Counted from the top of the list. The floor puts a shared boundary in the lower
        // row; the min catches the bottom edge, where the division lands exactly on
        // `entryCount`.
        let slot = min(Int((rowsTop - mouse.y) / metrics.rowHeight), entryCount - 1)
        return isFlipped ? entryCount - 1 - slot : slot
    }
}
