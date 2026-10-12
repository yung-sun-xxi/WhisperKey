import QuickPaste

public extension ThemeTokens {
    /// The quick paste popup's geometry (#166), from the shared tokens, as the token
    /// sheet's "Quick paste popup" adds it up: "1 (edge) + 36 + 1 (separator) + 8 + rows ×
    /// 34 + 8 + 1 (edge)". The shell's width (`panels.quickPaste`) and edge, a header bar
    /// one panel bar tall, a separator one edge wide (as the popover's dividers), list
    /// rows, and the rows' inset.
    ///
    /// The controller reads this once per reveal and hands the same value to the hit test
    /// (`QuickPasteLayout`) and to the view (`ThemedQuickPasteView`), so the row that is
    /// drawn highlighted is the row a release pastes.
    var quickPasteMetrics: QuickPasteMetrics {
        QuickPasteMetrics(
            width: panels.quickPaste.width,
            edgeWidth: panels.quickPaste.edgeWidth,
            headerHeight: sizes.panelBar,
            separatorHeight: panels.quickPaste.edgeWidth,
            rowHeight: sizes.listRow,
            rowInset: spacing.rowInset
        )
    }
}
