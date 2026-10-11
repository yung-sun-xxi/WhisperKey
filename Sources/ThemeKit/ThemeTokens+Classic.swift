import CoreGraphics

public extension ThemeTokens {
    /// Classic: what the views draw today (#105 rule 5). Each value names the view it was
    /// read from, so a surface moved onto a token keeps its look in Classic.
    ///
    /// Where today's surfaces disagree within one role, the value is the one the named
    /// view uses; a surface that draws the role differently gets its own token when it
    /// moves onto tokens. Where Classic leaves a role to AppKit (window chrome, switches,
    /// pop-up buttons, checkboxes), the value is what AppKit draws at the size the app
    /// uses, and is marked "system-drawn".
    static let classic = ThemeTokens(
        theme: .classic,
        colors: Colors(
            // No bar is filled today: the popover's footer and status line sit on its
            // material, and titlebars and the Settings tab well are the system's.
            bar: .system(.clear),
            // WelcomeWindow and the toast's close button: windowBackgroundColor.
            surface: .system(.windowBackground),
            // SettingsWindowLayout.backgroundColor, also the Reset usage window.
            settingsSurface: .system(.controlBackground),
            // HeaderSurfaceColor.bar: the usage tiles and the period picker track.
            card: .system(.primary, opacity: 0.075),
            // HeaderSurfaceColor.divider.
            divider: .system(.primary, opacity: 0.14),
            // QuickPasteRow, the highlighted row.
            selectedRow: .system(.accent, opacity: 0.22),
            // HeaderSurfaceColor.bar again: no control sits on a card today.
            raisedControl: .system(.primary, opacity: 0.075),
            // QuickPasteView, the panel's outline.
            edge: .system(.primary, opacity: 0.12),
            // DevBuildBadge's outline, the one muted edge drawn today.
            mutedEdge: .system(.secondaryLabel, opacity: 0.6),
            // PopoverTypography.secondaryColor.
            secondaryText: .system(.secondaryLabel),
            // HeaderPeriodPicker, the inactive segments: PopoverTypography.primaryColor.
            navigationText: .system(.label),
            // PopoverTypography.primaryColor.
            primaryText: .system(.label),
            // System-drawn: an AppKit checkbox fills with the accent colour.
            checkboxFill: .system(.accent),
            // HeaderPeriodPicker, the active segment.
            brand: .system(.accent),
            // Nothing in Classic changes on hover or press.
            brandHover: .system(.accent),
            // HeaderPeriodPicker, the active segment's label.
            onBrand: .system(.white),
            // CancelStatusIcon, the circle.
            recordingStop: .system(.red, opacity: 0.84),
            // CommandCenterHeader's status dot, HistorySection's saved mark.
            success: .system(.green),
            // A failed row is told apart by its secondary text only; no fill.
            failureFill: .system(.clear),
            failureHatch: .system(.clear),
            // System-drawn: the switch's knob is white.
            offKnob: .system(.white),
            // Settings: Reset usage… and the API key's trash, both `.red` today.
            destructiveText: .system(.red),
            destructiveGlyph: .system(.red),
            // Settings: "Invalid key" and the Launch at login error, `.red`.
            failureText: .system(.red),
            // Settings: "Not verified", `.orange`.
            cautionText: .system(.orange),
            // Settings: the validate shield at rest, `.primary`.
            actionGlyph: .system(.primary),
            // ThemePicker, an unselected chip.
            chipEdge: .system(.primary, opacity: 0.15)
        ),
        type: TypeScale(
            // UsageMetricColumn's figures.
            statValue: ThemeFont(size: 14, weight: .semibold, tabularDigits: true),
            // PopoverTypography.strongSectionTitle.
            title: ThemeFont(size: 13, weight: .semibold),
            // PopoverTypography.base.
            body: ThemeFont(size: 13, weight: .regular),
            bodyLineHeight: nil,
            // PopoverTypography.button: Settings, Quit, the period picker.
            small: ThemeFont(size: 12, weight: .regular),
            // UsageMetricColumn's units ("words", "audio").
            caption: ThemeFont(size: 11, weight: .medium),
            // QuickPasteView's "Clipboard" header.
            capsHeader: ThemeFont(size: 10, weight: .semibold),
            // System-drawn: the Settings toolbar tab and the segmented Picker label.
            labelOnBrand: ThemeFont(size: 12, weight: .regular),
            // HeaderPeriodPicker, the active segment: PopoverTypography.button.
            segmentLabelOnBrand: ThemeFont(size: 12, weight: .regular),
            // System-drawn: a push button's label.
            defaultButton: ThemeFont(size: 13, weight: .regular),
            // No check mark is drawn by the app today; the system checkbox draws its
            // own. Kept at the Midnight value so the token is never empty.
            checkMark: ThemeFont(size: 10, weight: .bold),
            // Settings: `.caption` and `.caption2`, both 10pt regular on macOS.
            fieldCaption: ThemeFont(size: 10, weight: .regular),
            // SettingsWindowLayout.settingsActionIconSize, semibold.
            actionGlyph: ThemeFont(size: 14, weight: .semibold)
        ),
        radii: Radii(
            // System-drawn window corners.
            window: 10,
            // UsageSummaryRow and HeaderPeriodPicker's track.
            card: 7,
            // QuickPasteRow's highlight.
            row: 6,
            // System-drawn mini switch: a capsule.
            toggle: 8,
            // PermissionBanner, the theme chips, the history cards.
            control: 6,
            // HeaderPeriodPicker, the active segment.
            segment: 5,
            // System-drawn segmented Picker.
            modeSegment: 4,
            // System-drawn checkbox.
            checkbox: 4
        ),
        sizes: Sizes(
            // HistorySection.inlineRowHeight and QuickPasteLayout.rowHeight.
            listRow: 26,
            // The Settings window is one size in both themes (2026-10-11): rows of 32,
            // the old 24 row plus its 8 spacing. The system controls keep their size,
            // centred in the row.
            formRow: 32,
            // No panel bar is drawn today; the popover's footer is a row of buttons.
            panelBar: 24,
            // System-drawn titlebar: 32 on macOS 27.0.1, measured as a titled window's
            // frame height less its content rect (`[.titled, .closable,
            // .miniaturizable]`, as the Settings window). Settings' tab well makes up
            // the difference to Midnight's drawn 44 from it.
            titlebar: 32,
            // No action bar is drawn today; Reset usage ends in a button row.
            actionBar: 44,
            // System-drawn menu item.
            menuItem: 22,
            // SettingsWindowLayout.settingsControlHeight.
            control: 22,
            // The popover's status control frame.
            keycap: 18,
            // System-drawn mini switch.
            toggle: CGSize(width: 26, height: 15),
            // System-drawn checkbox.
            checkbox: 14,
            // CommandCenterHeader's status dot.
            dot: 7,
            // No selected-row bar is drawn today.
            selectionBar: CGSize(width: 2, height: 18),
            // HeaderPeriodPicker: segments of minimum height 21 in a 1.5 padding.
            periodSegment: 21,
            periodTrack: 24,
            // System-drawn segmented Picker at the settings control height.
            modeSegment: 20,
            modeTrack: 22
        ),
        spacing: Spacing(
            // The paddings and stack spacings the views use today.
            steps: [1, 2, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, 24],
            // PopoverContent.contentInsets, leading and trailing.
            panelTextEdge: 16,
            // SettingsWindowLayout.contentPadding.
            windowTextEdge: 18,
            // QuickPasteLayout.horizontalPadding.
            rowInset: 4,
            // QuickPasteRow's horizontal padding.
            rowPadding: 8
        ),
        panels: Panels(
            // MenuBarLayout.popoverWidth, MenuBarPanel.cornerRadius, PopoverChromeView's
            // `.popover` material, the panel's own window shadow.
            popover: PanelShell(
                width: 306,
                radius: 12,
                background: .material(.popover),
                edge: nil,
                edgeWidth: 0,
                shadow: .system
            ),
            // QuickPasteLayout.contentWidth and QuickPasteView's shell.
            quickPaste: PanelShell(
                width: 320,
                radius: 10,
                background: .material(.popover),
                edge: .system(.primary, opacity: 0.12),
                edgeWidth: 1,
                shadow: .system
            ),
            // ToastView: contentWidth, the card's radius, outline and drop shadow
            // (SwiftUI radius 8, so blur 16).
            toast: PanelShell(
                width: 380,
                radius: 14,
                background: .material(.hudWindow),
                edge: .system(.primary, opacity: 0.08),
                edgeWidth: 0.5,
                shadow: .drop(color: .system(.black, opacity: 0.22), blur: 16, x: 0, y: 3)
            )
        ),
        shadows: Shadows(
            window: .system,
            menu: .system,
            alert: .system
        ),
        controls: .system,
        windowChrome: .system,
        // Classic renders the system's controls, so most of these are what the system
        // draws ("system-drawn") or are not drawn at all ("unused"); the rest are the
        // sizes the Settings views set on those controls today.
        controlMetrics: ControlMetrics(
            edgeWidth: 1,             // system-drawn
            horizontalPadding: 10,    // unused: the system pads its own controls
            popUpMinWidth: 0,         // the system pop-up fits its title
            popUpTitleGap: 10,        // unused
            popUpChevron: 3.5,        // unused
            popUpChevronGap: 3,       // unused
            segmentedWidth: 150,      // the slot; the system control keeps its own width
            trackPadding: 2,          // unused
            segmentGap: 2,            // unused
            toggleKnob: 13,           // system-drawn small switch
            toggleKnobInset: 1,       // system-drawn
            numberFieldWidth: 64,     // the rounded-border number fields
            numberUnitGap: 6,         // HStack(spacing: 6)
            stepper: CGSize(width: 17, height: 20), // system-drawn small stepper
            stepperGap: 6,            // HStack(spacing: 6)
            stepperArrow: 4,          // unused
            stepperArrowGap: 4,       // unused
            secureFieldWidth: 108,    // the API key field
            rowControlGap: 6,         // the API key row's HStack(spacing: 6)
            badgeDotGap: 5,           // unused: Classic's badge is a Label
            badgeHeight: 22,          // the badge's minHeight: settingsControlHeight
            badgePadding: 0,          // Classic's badge has no box
            failureDash: [3, 3]       // unused
        ),
        // One window in both themes (decided 2026-10-11): Midnight's width, row area,
        // text edge and tab track, so the frame is the same size on every tab.
        settingsWindow: SettingsWindowMetrics(
            width: 520,
            // Midnight's window edge. `spacing.windowTextEdge` stays 18 for Classic's
            // other windows.
            textEdge: 20,
            rowAreaTop: 10,
            rowAreaBottom: 16,
            // Rows back to back, as in Midnight.
            rowSpacing: 0,
            // SettingsWindowLayout.settingsRowColumnSpacing.
            labelSpacing: 12,
            // Midnight's track (26 segments, padded 2, 2 apart) in Classic's colours and
            // radii. The band is padded Midnight's 14 plus half of what the system
            // titlebar lacks against Midnight's drawn bar, (44 - 32) / 2 = 6, above and
            // below, so both headers end 104 below the top of the frame.
            tabWellPadding: 20,
            tabSegmentHeight: 26,
            tabTrackPadding: 2,
            tabSegmentGap: 2,
            dividerWidth: 1,
            // ThemePicker's constants.
            chipIcon: 20,
            chipIconGap: 5,
            chipPadding: 6,
            chipSelectedOutline: 2,
            chipSpacing: 8,
            // LaunchAtLoginToggle's VStack(spacing: 4).
            errorLineGap: 4,
            // The Quick paste hint line, the same in both themes.
            hintLineHeight: 16
        )
    )
}
