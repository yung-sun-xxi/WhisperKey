import QuickPaste

public extension ThemeTokens {
    /// The quick paste popup's geometry (#166), from the shared tokens: the shell's width
    /// (`panels.quickPaste`), a header band one list row tall like the popover's "History"
    /// row, list rows, and the rows' inset from the shell.
    ///
    /// The controller reads this once per reveal and hands the same value to the hit test
    /// (`QuickPasteLayout`) and to the view (`ThemedQuickPasteView`), so the row that is
    /// drawn highlighted is the row a release pastes.
    var quickPasteMetrics: QuickPasteMetrics {
        QuickPasteMetrics(
            width: panels.quickPaste.width,
            headerHeight: sizes.listRow,
            rowHeight: sizes.listRow,
            rowInset: spacing.rowInset
        )
    }
}
