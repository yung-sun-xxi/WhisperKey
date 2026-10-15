import CoreGraphics

public extension ThemeTokens {
    /// Midnight: `docs/design/tokens.md`, the token sheet of the approved design, plus
    /// the values its surfaces use that the sheet does not list (the end of that file).
    /// `TokenSheetTests` reads the file and holds these to it.
    static let midnight = ThemeTokens(
        theme: .midnight,
        colors: Colors(
            bar: .hex(0x14161A),            // 01
            surface: .hex(0x1A1C21),        // 02
            settingsSurface: .hex(0x1A1C21), // 02
            card: .hex(0x23262D),           // 03
            divider: .hex(0x23262D),        // 03
            selectedRow: .hex(0x2E323B),    // 04
            raisedControl: .hex(0x2E323B),  // 04
            edge: .hex(0x3B4150),           // 05
            mutedEdge: .hex(0x5A6070),      // 06
            secondaryText: .hex(0x9BA1AF),  // 07
            navigationText: .hex(0xB4BAC6), // 07n
            primaryText: .hex(0xE8EAEF),    // 08
            checkboxFill: .hex(0xE8EAEF),   // 08
            brand: .hex(0xE24631),          // red
            brandHover: .hex(0xD0331F),     // red hover
            onBrand: .hex(0x14161A),        // on red
            recordingStop: .hex(0xE24631),  // red, #105 rule 1
            success: .hex(0x78BE20),        // green
            failureFill: .hex(0x1E2126),    // failure
            failureHatch: .hex(0x8A909E, opacity: 0.18),
            offKnob: .hex(0x8A909E),        // off knob
            // #105 rule 2: destructive actions look like their neighbours.
            destructiveText: .hex(0xE8EAEF),  // 08, a push button's label
            destructiveGlyph: .hex(0x9BA1AF), // 07
            // Rule 1: a failure is a state, not a brand moment; the dashed 06 edge marks it.
            failureText: .hex(0xE8EAEF),    // 08
            cautionText: .hex(0x9BA1AF),    // 07
            actionGlyph: .hex(0x9BA1AF),    // 07
            chipEdge: .hex(0x3B4150)        // 05, every edge
        ),
        type: TypeScale(
            statValue: ThemeFont(size: 15, weight: .semibold, tabularDigits: true),
            title: ThemeFont(size: 13, weight: .semibold),
            body: ThemeFont(size: 13, weight: .regular),
            bodyLineHeight: 1.45,
            small: ThemeFont(size: 12, weight: .regular),
            caption: ThemeFont(size: 11, weight: .regular),
            capsHeader: ThemeFont(size: 11, weight: .medium, trackingEm: 0.06),
            // Not on the sheet: the active Settings tab and "Hold" segment.
            labelOnBrand: ThemeFont(size: 12, weight: .medium),
            // Not on the sheet: the active period segment.
            segmentLabelOnBrand: ThemeFont(size: 11, weight: .medium),
            defaultButton: ThemeFont(size: 13, weight: .medium),
            // Not on the sheet, and below its type floor of 11.
            checkMark: ThemeFont(size: 10, weight: .bold),
            // 11/400: units, badges.
            fieldCaption: ThemeFont(size: 11, weight: .regular),
            // The design draws no glyph button; the size the app used before it.
            actionGlyph: ThemeFont(size: 14, weight: .semibold)
        ),
        radii: Radii(
            window: 10,
            card: 8,
            row: 8,
            toggle: 8,
            control: 6,
            segment: 6,
            // Not on the sheet: the "Hold / Toggle" segment.
            modeSegment: 4,
            checkbox: 4
        ),
        sizes: Sizes(
            listRow: 34,
            formRow: 32,
            panelBar: 36,
            titlebar: 44,
            actionBar: 48,
            menuItem: 30,
            control: 26,
            keycap: 18,
            toggle: CGSize(width: 28, height: 16),
            checkbox: 14,
            dot: 6,
            selectionBar: CGSize(width: 2, height: 18),
            // Not on the sheet: the segment heights in their tracks.
            periodSegment: 24,
            periodTrack: 28,
            modeSegment: 22,
            modeTrack: 26
        ),
        spacing: Spacing(
            steps: [2, 3, 4, 6, 8, 10, 14, 16, 20],
            panelTextEdge: 16,
            windowTextEdge: 20,
            rowInset: 8,
            rowPadding: 8
        ),
        panels: Panels(
            popover: .midnight(width: 320),
            quickPaste: .midnight(width: 328),
            toast: .midnight(width: 380)
        ),
        // Not on the sheet: the shadows the mockups draw.
        shadows: Shadows(
            window: .drop(color: .hex(0x000000, opacity: 0.45), blur: 52, x: 0, y: 24),
            menu: .drop(color: .hex(0x000000, opacity: 0.5), blur: 36, x: 0, y: 18),
            alert: .drop(color: .hex(0x000000, opacity: 0.6), blur: 44, x: 0, y: 20),
            // The app's earlier close disc: black at 18%, radius 1.5, 0.5 down.
            closeButton: .drop(color: .hex(0x000000, opacity: 0.18), blur: 3, x: 0, y: 0.5)
        ),
        windowAppearance: .dark,
        // Not on the sheet: the controls of the Settings mockups (tokens.md, gaps item 11).
        controlMetrics: ControlMetrics(
            edgeWidth: 1,
            horizontalPadding: 10,
            popUpMinWidth: 150,
            popUpTitleGap: 10,
            popUpChevron: 3.5,
            popUpChevronGap: 3,
            segmentedWidth: 150,
            trackPadding: 2,
            segmentGap: 2,
            toggleKnob: 12,
            toggleKnobInset: 2,
            // Not in the mockup, which sizes the box to "30": four tabular digits.
            numberFieldWidth: 36,
            numberUnitGap: 8,
            stepper: CGSize(width: 22, height: 26),
            stepperGap: 6,
            stepperArrow: 4,
            stepperArrowGap: 4,
            secureFieldWidth: 150,
            rowControlGap: 8,
            badgeDotGap: 5,
            badgeHeight: 20,
            badgePadding: 8,
            // "1px dashed": the browser's dash for a 1px edge.
            failureDash: [3, 3],
            // The failed row's "repeating-linear-gradient(135deg, … 0 4px, … 4px 9px)".
            failureHatchStripe: 4,
            failureHatchPeriod: 9
        ),
        // Not on the sheet: the Settings mockups (tokens.md, gaps item 10).
        settingsWindow: SettingsWindowMetrics(
            // The sheet's "+ settings window", both themes. macOS draws the window's edge
            // inside its frame, so the frame is 520 and the row area 480.
            width: 520,
            // The sheet's text edge in windows, `spacing.windowTextEdge`.
            textEdge: 20,
            rowAreaTop: 10,
            rowAreaBottom: 16,
            rowSpacing: 0,
            // The label is flexible in the mockup; the least gap is the sheet's 12.
            labelSpacing: 12,
            tabWellPadding: 14,
            tabSegmentHeight: 26,
            tabTrackPadding: 2,
            tabSegmentGap: 2,
            dividerWidth: 1,
            // The mockup has no Theme row; the chips keep the app's earlier sizes at
            // the control height.
            chipIcon: 20,
            chipIconGap: 5,
            chipPadding: 6,
            chipSelectedOutline: 2,
            chipSpacing: 8,
            // Not in the mockup either; the app's earlier gap.
            errorLineGap: 4,
            // Not in the mockup: the Quick paste hint line, one height in both themes.
            hintLineHeight: 16
        ),
        // Not on the sheet: the POPOVER section of the design file
        // (`docs/design/dark/master-design.dc.html`), quoted where it draws the value.
        popover: PopoverMetrics(
            sectionTop: 14,           // the usage block, "padding:14px 16px 0"
            usageGap: 8,              // the period picker, "margin-top:8px"
            togglesTop: 10,           // the toggles, "padding:10px 8px 0"
            listBottom: 8,            // the list, "padding:0 8px 8px"
            // Not in the design, which has no history buttons: one step above 8.
            buttonsBottom: 10,
            headerGap: 10,            // the header row, "gap:10px"
            statInsetVertical: 9,     // "padding:9px 10px", the sheet's "Stat tile inset 9×10"
            statInsetHorizontal: 10,
            statLabelGap: 2,          // the stat label, "margin-top:2px"
            statDividerInset: 9,      // the stat dividers, "margin:9px 0"
            chevronSegment: 26,       // "width:26px"
            chevronArm: 6,            // "width:6px;height:6px"
            chevronStroke: 1.5,       // "border-top:1.5px"
            // Not in the design, which stacks the toggles in two rows; the app keeps
            // them side by side. The gap is a step, the divider as tall as a keycap.
            toggleGap: 14,
            toggleDividerHeight: 18,
            rowGap: 10,               // a list row, "gap:10px"
            // Not in the design, which drops the stop button for a status line; the
            // app keeps it at about its earlier size.
            stopButton: 16,
            stopSquare: 6,
            stopSquareRadius: 1.5,
            // Not in the design, which has no permission banner.
            bannerPadding: 10,
            bannerGap: 4,
            keycapPadding: 4,         // a keycap, "padding:0 4px"
            // The app's earlier count; the design shows seven rows too.
            visibleRows: 7
        ),
        // The sheet's "Quick paste popup": "marker column | 14 wide, leading, on every
        // row; 8 gap before the text", "marker symbol | 11pt, 07", both symbols
        // `.semibold`.
        quickPasteMarker: QuickPasteMarkerMetrics(
            width: 14,
            gap: 8,
            font: ThemeFont(size: 11, weight: .semibold)
        ),
        // Not on the sheet: the TOAST section of the design file, quoted where it draws
        // the value, and the app's own close disc and placement (#167).
        toast: ToastMetrics(
            // The app's: the clear room the close disc overhangs into, and the card 12
            // from the screen's right edge and 8 under the menu bar.
            margin: 10,
            screenEdgeInset: 12,
            menuBarGap: 8,
            padding: 14,              // "padding:14px 14px 14px 16px"
            leadingPadding: 16,
            glyphColumn: 18,          // "width:18px"
            glyphTop: 8,              // "padding-top:8px"
            glyphGap: 10,             // "gap:10px"
            // The SF Symbol about as tall as the design's 14×18 microphone.
            glyph: ThemeFont(size: 15, weight: .regular),
            title: ThemeFont(size: 11, weight: .regular),   // "font-size:11px", the caption
            titleGap: 1,              // "margin-top:1px"
            message: ThemeFont(size: 13, weight: .regular), // "font-size:13px", the body
            messageLineHeight: 1.45,  // "line-height:1.45", the body's
            actionGap: 10,            // "margin-top:10px"
            // The app's close disc, which the design does not draw.
            closeButton: 20,
            closeGlyph: ThemeFont(size: 9, weight: .bold),
            closeEdgeWidth: 0.5
        ),
        // Not on the sheet: the FULL HISTORY section of the design file, quoted where it
        // draws the value, and the app's own window size (#164).
        fullHistory: FullHistoryMetrics(
            // The app's: 560 × 500 under the titlebar, at least 420 × 320.
            contentSize: CGSize(width: 560, height: 500),
            minContentSize: CGSize(width: 420, height: 320),
            dividerWidth: 1,          // "border-top:1px solid #23262D"
            // "font-size:13px;color:#E8EAEF;font-variant-numeric:tabular-nums"
            count: ThemeFont(size: 13, weight: .regular, tabularDigits: true),
            countGap: 6,              // the count bar, "gap:6px"
            listPaddingVertical: 8,   // the list area, "padding:8px 12px"
            listPaddingHorizontal: 12,
            rowGap: 10,               // a row, "gap:10px", as the popover's
            // A failed row, "gap:8px"; its timestamp's "margin-left:2px" makes 10.
            failedRowGap: 8,
            // "font-size:11px;color:#9BA1AF;font-variant-numeric:tabular-nums"
            timestamp: ThemeFont(size: 11, weight: .regular, tabularDigits: true),
            // The sheet's "+ empty-list glyph | 22 | SF title size, tray in Full history",
            // and "4 above a 13/400 line in 07".
            emptyGlyph: ThemeFont(size: 22, weight: .regular),
            emptyGap: 4
        ),
        // Not on the sheet: the HISTORY READER section of the design file, quoted where it
        // draws the value, the app's own window size, and the ticket's language tag (#165).
        historyReader: HistoryReaderMetrics(
            // The app's: 480 × 280 under the titlebar, at least 360 × 220.
            contentSize: CGSize(width: 480, height: 280),
            minContentSize: CGSize(width: 360, height: 220),
            dividerWidth: 1,            // "border-top:1px solid #23262D"
            contentPaddingVertical: 14, // the content, "gap:8px;padding:14px 20px"
            contentGap: 8,
            // "font-size:11px;color:#9BA1AF;font-variant-numeric:tabular-nums"
            date: ThemeFont(size: 11, weight: .regular, tabularDigits: true),
            // Not in the mockup: the ticket keeps the tag in caps right after the date;
            // the count bar's gap between a number and its noun.
            languageGap: 6,
            cardPaddingVertical: 10,    // the card, "padding:10px 14px"
            cardPaddingHorizontal: 14,
            actionGap: 8                // the action bar, "gap:8px;padding:0 20px"
        ),
        // Not on the sheet: the RESET USAGE section of the design file, quoted where it
        // draws the value (#183).
        resetUsage: ResetUsageMetrics(
            contentWidth: 420,          // "width:420px", the window's content
            contentPaddingTop: 14,      // the content, "padding:14px 20px 16px"
            contentPaddingBottom: 16,
            cardGap: 14,                // the card, "margin-top:14px"
            cardInset: 4,               // the card, "padding:0 4px 4px"
            rowGap: 10,                 // a row, "gap:10px"
            pillPadding: 6,             // the Current pill, "padding:0 6px"
            mixedMarkWidth: 8,          // the mixed mark, "width:8px;height:2px"
            mixedMarkHeight: 2,
            mixedMarkRadius: 1,
            actionGap: 8,               // the action bar, "gap:8px;padding:0 20px"
            // The app's earlier 160 pt list showed about six rows; the design shows four.
            visibleRows: 6
        ),
        // Not on the sheet: the USAGE BY MODEL section of the design file, quoted where it
        // draws the value (#184).
        usageBreakdown: UsageBreakdownMetrics(
            contentWidth: 540,          // "width:540px", every period
            barPaddingVertical: 14,     // the picker band, "padding:14px 20px"
            contentPaddingTop: 14,      // the content, "padding:14px 20px 20px"
            contentPaddingBottom: 20,
            cardInset: 4,               // the card, "padding:0 4px 4px"
            // "grid-template-columns:minmax(0,1fr) 56px 64px 48px;gap:12px"
            wordsColumn: 56,
            audioColumn: 64,
            costColumn: 48,
            columnGap: 12,
            emptyPaddingVertical: 40,   // the empty card, "padding:40px 16px"
            emptyPaddingHorizontal: 16
        )
    )
}

private extension PanelShell {
    /// The one shell the three panels share (#105 rule 4): radius 12, 02 at 95% over a
    /// blur of 30, a 05 edge, and the window server's shadow.
    static func midnight(width: CGFloat) -> PanelShell {
        PanelShell(
            width: width,
            radius: 12,
            background: .fill(.hex(0x1A1C21, opacity: 0.95), blur: 30),
            edge: .hex(0x3B4150),
            edgeWidth: 1,
            // The mockups draw "0 22px 48px rgba(0,0,0,0.5)". The owner kept the window
            // server's shadow instead (#161): a drawn one needs a window larger than the
            // panel, and a click on that shadow would land in the panel and stop
            // dismissing it.
            shadow: .system
        )
    }
}
