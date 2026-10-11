import CoreGraphics

/// The Settings window's height, added up from the tokens (#162).
///
/// The window must come out the same size in every theme on every tab (decided
/// 2026-10-11). The views lay themselves out from the same tokens; this states the sum
/// they produce, so a test can hold the themes to one frame without drawing a view.
///
/// From the top: the titlebar band (`sizes.titlebar`, in both themes — the content runs
/// under the transparent system titlebar), the tab well — a divider, the band padded
/// above and below around its track, a divider — then the row area: its top padding,
/// the rows back to back with any hint lines between them, its bottom padding. The frame
/// is the content: nothing sits above it.
public enum SettingsWindowGeometry {
    /// The tab well: two dividers, the band's padding and the track.
    public static func tabWellHeight(_ tokens: ThemeTokens) -> CGFloat {
        let window = tokens.settingsWindow
        return 2 * window.dividerWidth
            + 2 * window.tabWellPadding
            + window.tabSegmentHeight + 2 * window.tabTrackPadding
    }

    /// What the window draws above the panes: the titlebar band and the tab well.
    public static func headerHeight(_ tokens: ThemeTokens) -> CGFloat {
        tokens.sizes.titlebar + tabWellHeight(tokens)
    }

    /// A pane of `rows` form rows and `hintLines` hint lines.
    public static func paneHeight(_ tokens: ThemeTokens, rows: Int, hintLines: Int = 0) -> CGFloat {
        let window = tokens.settingsWindow
        let items = rows + hintLines
        let gaps = CGFloat(max(items - 1, 0)) * window.rowSpacing
        return window.rowAreaTop
            + CGFloat(rows) * tokens.sizes.formRow
            + CGFloat(hintLines) * window.hintLineHeight
            + gaps
            + window.rowAreaBottom
    }

    /// The window's content: the header and the pane.
    public static func contentHeight(_ tokens: ThemeTokens, rows: Int, hintLines: Int = 0) -> CGFloat {
        headerHeight(tokens) + paneHeight(tokens, rows: rows, hintLines: hintLines)
    }

    /// The window's frame: its content, in either theme.
    public static func frameHeight(_ tokens: ThemeTokens, rows: Int, hintLines: Int = 0) -> CGFloat {
        contentHeight(tokens, rows: rows, hintLines: hintLines)
    }
}
