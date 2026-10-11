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
            // The design draws no glyph button; Classic's size.
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
            alert: .drop(color: .hex(0x000000, opacity: 0.6), blur: 44, x: 0, y: 20)
        ),
        controls: .drawn,
        windowChrome: .drawn,
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
            failureDash: [3, 3]
        ),
        // Not on the sheet: the Settings mockups (tokens.md, gaps item 10).
        settingsWindow: SettingsWindowMetrics(
            // The mockup's outer width. macOS draws the window's edge inside its frame,
            // so the frame is 580 and the row area 540 (the mockup's 538 less its edge).
            width: 580,
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
            // The mockup has no Theme row; the chips keep Classic's sizes at the
            // control height.
            chipIcon: 20,
            chipIconGap: 5,
            chipPadding: 6,
            chipSelectedOutline: 2,
            chipSpacing: 8,
            // Not in the mockup either; Classic's.
            errorLineGap: 4
        )
    )
}

private extension PanelShell {
    /// The one shell the three panels share (#105 rule 4): radius 12, 02 at 95% over a
    /// blur of 30, a 05 edge, and the panel shadow the mockups draw.
    static func midnight(width: CGFloat) -> PanelShell {
        PanelShell(
            width: width,
            radius: 12,
            background: .fill(.hex(0x1A1C21, opacity: 0.95), blur: 30),
            edge: .hex(0x3B4150),
            edgeWidth: 1,
            shadow: .drop(color: .hex(0x000000, opacity: 0.5), blur: 48, x: 0, y: 22)
        )
    }
}
