import CoreGraphics
import SettingsStore

/// Everything a surface needs to know about the look of one theme: colours, type,
/// radii, sizes, spacing and shadows (#160, part of #105).
///
/// There is one value set per `AppTheme` case, `ThemeTokens.classic` and
/// `ThemeTokens.midnight`, and `AppTheme.tokens` picks it. A third theme is one new
/// `AppTheme` case plus one value set; the switch in `AppTheme.tokens` refuses to
/// compile until the value set exists.
///
/// The values are descriptions — hex numbers, system colour names, sizes and weights —
/// rather than SwiftUI `Color` and `Font`, so they can be compared in a unit test.
/// `ThemeColor.color` and `ThemeFont.font` turn them into SwiftUI values at the view.
///
/// The names follow the roles of the Midnight token sheet (`docs/design/tokens.md`);
/// each doc comment quotes the sheet's number or usage. The themes differ only in
/// colours (decided 2026-10-11): one layout, one set of drawn controls, one window
/// chrome. Classic is Midnight under its own id until it gets its own palette.
public struct ThemeTokens: Equatable, Sendable {
    public var theme: AppTheme
    public var colors: Colors
    public var type: TypeScale
    public var radii: Radii
    public var sizes: Sizes
    public var spacing: Spacing
    public var panels: Panels
    public var shadows: Shadows
    /// The appearance a themed window takes, so the system's titlebar, menus and alerts
    /// match the palette.
    public var windowAppearance: WindowAppearance
    /// The sizes of the drawn controls that the sheet does not name.
    public var controlMetrics: ControlMetrics
    /// The Settings window: its width, row area, tab well and Theme chips.
    public var settingsWindow: SettingsWindowMetrics

    public init(
        theme: AppTheme,
        colors: Colors,
        type: TypeScale,
        radii: Radii,
        sizes: Sizes,
        spacing: Spacing,
        panels: Panels,
        shadows: Shadows,
        windowAppearance: WindowAppearance,
        controlMetrics: ControlMetrics,
        settingsWindow: SettingsWindowMetrics
    ) {
        self.theme = theme
        self.colors = colors
        self.type = type
        self.radii = radii
        self.sizes = sizes
        self.spacing = spacing
        self.panels = panels
        self.shadows = shadows
        self.windowAppearance = windowAppearance
        self.controlMetrics = controlMetrics
        self.settingsWindow = settingsWindow
    }
}

/// The system appearance of a themed window: dark for a dark palette, light for a light
/// one. Named here so the token stays free of AppKit; the window maps it.
public enum WindowAppearance: String, Equatable, Sendable {
    case dark
    case light
}

public extension AppTheme {
    /// The value set this theme draws with.
    var tokens: ThemeTokens {
        switch self {
        case .classic: return .classic
        case .midnight: return .midnight
        }
    }
}

// MARK: - Colours

public extension ThemeTokens {
    struct Colors: Equatable, Sendable {
        /// 01. Bars: status, footer, titlebar, tab well, action bar.
        public var bar: ThemeColor
        /// 02. The surface of a window, solid.
        public var surface: ThemeColor
        /// 02 as well in Midnight. Settings and Reset usage.
        public var settingsSurface: ThemeColor
        /// 03. Cards, controls, tracks.
        public var card: ThemeColor
        /// 03. Dividers on the 02 surface.
        public var divider: ThemeColor
        /// 04. Hover and selected row.
        public var selectedRow: ThemeColor
        /// 04. Inactive keycap, off track, a control sitting on an 03 card.
        public var raisedControl: ThemeColor
        /// 05. Every edge: shell, control outline, active keycap, divider on 03.
        public var edge: ThemeColor
        /// 06. Dashed failure edge, unchecked checkbox edge. Never text.
        public var mutedEdge: ThemeColor
        /// 07. Secondary type.
        public var secondaryText: ThemeColor
        /// 07n. Navigation at rest: inactive tabs and segments.
        public var navigationText: ThemeColor
        /// 08. Primary type.
        public var primaryText: ThemeColor
        /// 08. Checked checkbox fill.
        public var checkboxFill: ThemeColor
        /// red. Trigger caps, active segment and tab, toggle on, selected-row bar,
        /// default button, the stop button while recording.
        public var brand: ThemeColor
        /// red hover. Hover and pressed on any red fill.
        public var brandHover: ThemeColor
        /// on red. All type and glyphs on a red fill; 01 also marks a checkbox.
        public var onBrand: ThemeColor
        /// The stop button while recording. Brand red in Midnight (#105 rule 1).
        public var recordingStop: ThemeColor
        /// green. The 6pt dot only: Connected, Saved, Granted.
        public var success: ThemeColor
        /// failure. The fill under a failed row's hatch.
        public var failureFill: ThemeColor
        /// failure. The hatch stroke over that fill, at 18%.
        public var failureHatch: ThemeColor
        /// off knob. Off-toggle knob. Shapes only.
        public var offKnob: ThemeColor
        /// The label of a destructive push button (Reset usage…). It looks like its
        /// neighbours (#105 rule 2).
        public var destructiveText: ThemeColor
        /// A destructive glyph (the API key's trash). 07 in Midnight.
        public var destructiveGlyph: ThemeColor
        /// Text that reports a failure: "Invalid key", the Launch at login error. 08 in
        /// Midnight, where a failure is a state, not a colour (rule 1).
        public var failureText: ThemeColor
        /// Text that reports a doubt: "Not verified". 07 in Midnight.
        public var cautionText: ThemeColor
        /// A glyph button at rest: the API key's validate shield.
        public var actionGlyph: ThemeColor
        /// The outline of an unselected Theme chip.
        public var chipEdge: ThemeColor

        public init(
            bar: ThemeColor,
            surface: ThemeColor,
            settingsSurface: ThemeColor,
            card: ThemeColor,
            divider: ThemeColor,
            selectedRow: ThemeColor,
            raisedControl: ThemeColor,
            edge: ThemeColor,
            mutedEdge: ThemeColor,
            secondaryText: ThemeColor,
            navigationText: ThemeColor,
            primaryText: ThemeColor,
            checkboxFill: ThemeColor,
            brand: ThemeColor,
            brandHover: ThemeColor,
            onBrand: ThemeColor,
            recordingStop: ThemeColor,
            success: ThemeColor,
            failureFill: ThemeColor,
            failureHatch: ThemeColor,
            offKnob: ThemeColor,
            destructiveText: ThemeColor,
            destructiveGlyph: ThemeColor,
            failureText: ThemeColor,
            cautionText: ThemeColor,
            actionGlyph: ThemeColor,
            chipEdge: ThemeColor
        ) {
            self.bar = bar
            self.surface = surface
            self.settingsSurface = settingsSurface
            self.card = card
            self.divider = divider
            self.selectedRow = selectedRow
            self.raisedControl = raisedControl
            self.edge = edge
            self.mutedEdge = mutedEdge
            self.secondaryText = secondaryText
            self.navigationText = navigationText
            self.primaryText = primaryText
            self.checkboxFill = checkboxFill
            self.brand = brand
            self.brandHover = brandHover
            self.onBrand = onBrand
            self.recordingStop = recordingStop
            self.success = success
            self.failureFill = failureFill
            self.failureHatch = failureHatch
            self.offKnob = offKnob
            self.destructiveText = destructiveText
            self.destructiveGlyph = destructiveGlyph
            self.failureText = failureText
            self.cautionText = cautionText
            self.actionGlyph = actionGlyph
            self.chipEdge = chipEdge
        }
    }
}

// MARK: - Type

public extension ThemeTokens {
    struct TypeScale: Equatable, Sendable {
        /// 15/600. Stat values, tabular.
        public var statValue: ThemeFont
        /// 13/600. Window title, alert title, in-window heading.
        public var title: ThemeFont
        /// 13/400. Row labels, values, buttons, body text.
        public var body: ThemeFont
        /// Body line height as a multiple of the size; `nil` leaves the system's.
        public var bodyLineHeight: Double?
        /// 12/400. Status line, footer, tabs, description lines.
        public var small: ThemeFont
        /// 11/400. Timestamps, keycaps, units, badges.
        public var caption: ThemeFont
        /// 11/500, tracked 0.06em. Caps headers.
        public var capsHeader: ThemeFont
        /// 12/500. The label on a red fill: the active Settings tab, the active
        /// "Hold / Toggle" segment.
        public var labelOnBrand: ThemeFont
        /// 11/500. The active period segment of the popover.
        public var segmentLabelOnBrand: ThemeFont
        /// 13/500. The default button's label.
        public var defaultButton: ThemeFont
        /// 10/700. The check mark in Full history.
        public var checkMark: ThemeFont
        /// Units, hints, badges and error lines in the Settings rows.
        public var fieldCaption: ThemeFont
        /// A glyph button in a Settings row: the API key's shield and trash.
        public var actionGlyph: ThemeFont

        public init(
            statValue: ThemeFont,
            title: ThemeFont,
            body: ThemeFont,
            bodyLineHeight: Double?,
            small: ThemeFont,
            caption: ThemeFont,
            capsHeader: ThemeFont,
            labelOnBrand: ThemeFont,
            segmentLabelOnBrand: ThemeFont,
            defaultButton: ThemeFont,
            checkMark: ThemeFont,
            fieldCaption: ThemeFont,
            actionGlyph: ThemeFont
        ) {
            self.statValue = statValue
            self.title = title
            self.body = body
            self.bodyLineHeight = bodyLineHeight
            self.small = small
            self.caption = caption
            self.capsHeader = capsHeader
            self.labelOnBrand = labelOnBrand
            self.segmentLabelOnBrand = segmentLabelOnBrand
            self.defaultButton = defaultButton
            self.checkMark = checkMark
            self.fieldCaption = fieldCaption
            self.actionGlyph = actionGlyph
        }
    }
}

// MARK: - Radii

public extension ThemeTokens {
    struct Radii: Equatable, Sendable {
        /// 10. Window shell, actions menu.
        public var window: CGFloat
        /// 8. Cards and tracks.
        public var card: CGFloat
        /// 8. Rows.
        public var row: CGFloat
        /// 8. Toggles.
        public var toggle: CGFloat
        /// 6. Keycaps, fields, buttons, badges.
        public var control: CGFloat
        /// The active segment inside a period-picker track.
        public var segment: CGFloat
        /// 4. The "Hold / Toggle" segment, 22 tall.
        public var modeSegment: CGFloat
        /// 4. Checkbox.
        public var checkbox: CGFloat

        public init(
            window: CGFloat,
            card: CGFloat,
            row: CGFloat,
            toggle: CGFloat,
            control: CGFloat,
            segment: CGFloat,
            modeSegment: CGFloat,
            checkbox: CGFloat
        ) {
            self.window = window
            self.card = card
            self.row = row
            self.toggle = toggle
            self.control = control
            self.segment = segment
            self.modeSegment = modeSegment
            self.checkbox = checkbox
        }
    }
}

// MARK: - Sizes

public extension ThemeTokens {
    struct Sizes: Equatable, Sendable {
        /// 34. List row: popover, quick paste, full history, checklist.
        public var listRow: CGFloat
        /// 32. Form row: Settings.
        public var formRow: CGFloat
        /// 36. Panel bar.
        public var panelBar: CGFloat
        /// 44. Titlebar.
        public var titlebar: CGFloat
        /// 48. Action bar.
        public var actionBar: CGFloat
        /// 30. Menu item.
        public var menuItem: CGFloat
        /// 26. Control.
        public var control: CGFloat
        /// 18. Keycap, badge.
        public var keycap: CGFloat
        /// 28×16. Toggle.
        public var toggle: CGSize
        /// 14. Checkbox.
        public var checkbox: CGFloat
        /// 6. Status dot.
        public var dot: CGFloat
        /// 2×18. Selected-row bar.
        public var selectionBar: CGSize
        /// 24. A period segment, inside a 28 track.
        public var periodSegment: CGFloat
        /// 28. The period picker's track.
        public var periodTrack: CGFloat
        /// 22. A "Hold / Toggle" segment, inside a 26 track.
        public var modeSegment: CGFloat
        /// 26. The "Hold / Toggle" track.
        public var modeTrack: CGFloat

        public init(
            listRow: CGFloat,
            formRow: CGFloat,
            panelBar: CGFloat,
            titlebar: CGFloat,
            actionBar: CGFloat,
            menuItem: CGFloat,
            control: CGFloat,
            keycap: CGFloat,
            toggle: CGSize,
            checkbox: CGFloat,
            dot: CGFloat,
            selectionBar: CGSize,
            periodSegment: CGFloat,
            periodTrack: CGFloat,
            modeSegment: CGFloat,
            modeTrack: CGFloat
        ) {
            self.listRow = listRow
            self.formRow = formRow
            self.panelBar = panelBar
            self.titlebar = titlebar
            self.actionBar = actionBar
            self.menuItem = menuItem
            self.control = control
            self.keycap = keycap
            self.toggle = toggle
            self.checkbox = checkbox
            self.dot = dot
            self.selectionBar = selectionBar
            self.periodSegment = periodSegment
            self.periodTrack = periodTrack
            self.modeSegment = modeSegment
            self.modeTrack = modeTrack
        }
    }
}

// MARK: - Spacing

public extension ThemeTokens {
    struct Spacing: Equatable, Sendable {
        /// The spacing steps, ascending. Views pick from these.
        public var steps: [CGFloat]
        /// 16. Text edge in panels.
        public var panelTextEdge: CGFloat
        /// 20. Text edge in windows.
        public var windowTextEdge: CGFloat
        /// 8. Rows inset from the shell.
        public var rowInset: CGFloat
        /// 8. Padding inside a row.
        public var rowPadding: CGFloat

        public init(
            steps: [CGFloat],
            panelTextEdge: CGFloat,
            windowTextEdge: CGFloat,
            rowInset: CGFloat,
            rowPadding: CGFloat
        ) {
            self.steps = steps
            self.panelTextEdge = panelTextEdge
            self.windowTextEdge = windowTextEdge
            self.rowInset = rowInset
            self.rowPadding = rowPadding
        }
    }
}

// MARK: - Panels and shadows

public extension ThemeTokens {
    /// The three floating panels. The sheet gives them one shell (#105 rule 4); each
    /// keeps its own value for its width.
    struct Panels: Equatable, Sendable {
        public var popover: PanelShell
        public var quickPaste: PanelShell
        public var toast: PanelShell

        public init(popover: PanelShell, quickPaste: PanelShell, toast: PanelShell) {
            self.popover = popover
            self.quickPaste = quickPaste
            self.toast = toast
        }
    }

    struct Shadows: Equatable, Sendable {
        /// The window shell.
        public var window: ThemeShadow
        /// The actions menu.
        public var menu: ThemeShadow
        /// An alert.
        public var alert: ThemeShadow

        public init(window: ThemeShadow, menu: ThemeShadow, alert: ThemeShadow) {
            self.window = window
            self.menu = menu
            self.alert = alert
        }
    }
}

/// One floating panel's shell: how wide, how round, what fills it, its edge and shadow.
public struct PanelShell: Equatable, Sendable {
    public var width: CGFloat
    /// 12 for every panel in Midnight.
    public var radius: CGFloat
    public var background: PanelBackground
    /// `nil` draws no edge.
    public var edge: ThemeColor?
    public var edgeWidth: CGFloat
    public var shadow: ThemeShadow

    public init(
        width: CGFloat,
        radius: CGFloat,
        background: PanelBackground,
        edge: ThemeColor?,
        edgeWidth: CGFloat,
        shadow: ThemeShadow
    ) {
        self.width = width
        self.radius = radius
        self.background = background
        self.edge = edge
        self.edgeWidth = edgeWidth
        self.shadow = shadow
    }
}

/// What fills a floating panel.
public enum PanelBackground: Equatable, Sendable {
    /// An `NSVisualEffectView` blurring what lies behind the window.
    case material(PanelMaterial)
    /// A colour over a blur of the given radius: Midnight's 02 at 95%, blur 30.
    case fill(ThemeColor, blur: CGFloat)
}

/// The `NSVisualEffectView.Material` a panel uses. Named here so the token stays
/// free of AppKit; the view maps it.
public enum PanelMaterial: String, Equatable, Sendable {
    case popover
    case hudWindow
}

/// A shadow, either the one the window server draws for a window (`hasShadow`) or a drop
/// shadow drawn in SwiftUI.
public enum ThemeShadow: Equatable, Sendable {
    /// No shadow of ours: the window server's, or none for a view inside a window.
    case system
    /// `blur` is the CSS blur radius the design file states. SwiftUI's
    /// `.shadow(radius:)` takes half of it, which `swiftUIRadius` gives.
    case drop(color: ThemeColor, blur: CGFloat, x: CGFloat, y: CGFloat)

    public var swiftUIRadius: CGFloat? {
        guard case let .drop(_, blur, _, _) = self else { return nil }
        return blur / 2
    }
}

// MARK: - Controls and the Settings window

public extension ThemeTokens {
    /// The sizes of the drawn controls (#162) that the sheet does not name. Heights come
    /// from `sizes.control`, radii from `radii.control`; the rest is here.
    struct ControlMetrics: Equatable, Sendable {
        /// The outline of a control.
        public var edgeWidth: CGFloat
        /// Inside a push button, a pop-up, a number field and the API key field.
        public var horizontalPadding: CGFloat
        /// A pop-up's narrowest width.
        public var popUpMinWidth: CGFloat
        /// Between a pop-up's title and its chevrons.
        public var popUpTitleGap: CGFloat
        /// The height of each up or down chevron; its base is twice that.
        public var popUpChevron: CGFloat
        /// Between the two chevrons.
        public var popUpChevronGap: CGFloat
        /// The segmented control's width.
        public var segmentedWidth: CGFloat
        /// Inside a segmented track, around the segments.
        public var trackPadding: CGFloat
        /// Between two segments.
        public var segmentGap: CGFloat
        /// The toggle's knob, and its inset from the track's edge.
        public var toggleKnob: CGFloat
        public var toggleKnobInset: CGFloat
        /// The number's width inside the box.
        public var numberFieldWidth: CGFloat
        /// Between a number and its unit.
        public var numberUnitGap: CGFloat
        /// The stepper beside a number field.
        public var stepper: CGSize
        /// Between the number field and its stepper.
        public var stepperGap: CGFloat
        /// The height of each stepper triangle (base twice that), and the gap between them.
        public var stepperArrow: CGFloat
        public var stepperArrowGap: CGFloat
        /// The API key field's width.
        public var secureFieldWidth: CGFloat
        /// Between the controls of one row: badge, shield, field, trash.
        public var rowControlGap: CGFloat
        /// Between the Saved badge's dot and its word.
        public var badgeDotGap: CGFloat
        /// A badge's height and its padding inside the dashed edge.
        public var badgeHeight: CGFloat
        public var badgePadding: CGFloat
        /// Dash and gap of a dashed failure edge.
        public var failureDash: [CGFloat]

        public init(
            edgeWidth: CGFloat,
            horizontalPadding: CGFloat,
            popUpMinWidth: CGFloat,
            popUpTitleGap: CGFloat,
            popUpChevron: CGFloat,
            popUpChevronGap: CGFloat,
            segmentedWidth: CGFloat,
            trackPadding: CGFloat,
            segmentGap: CGFloat,
            toggleKnob: CGFloat,
            toggleKnobInset: CGFloat,
            numberFieldWidth: CGFloat,
            numberUnitGap: CGFloat,
            stepper: CGSize,
            stepperGap: CGFloat,
            stepperArrow: CGFloat,
            stepperArrowGap: CGFloat,
            secureFieldWidth: CGFloat,
            rowControlGap: CGFloat,
            badgeDotGap: CGFloat,
            badgeHeight: CGFloat,
            badgePadding: CGFloat,
            failureDash: [CGFloat]
        ) {
            self.edgeWidth = edgeWidth
            self.horizontalPadding = horizontalPadding
            self.popUpMinWidth = popUpMinWidth
            self.popUpTitleGap = popUpTitleGap
            self.popUpChevron = popUpChevron
            self.popUpChevronGap = popUpChevronGap
            self.segmentedWidth = segmentedWidth
            self.trackPadding = trackPadding
            self.segmentGap = segmentGap
            self.toggleKnob = toggleKnob
            self.toggleKnobInset = toggleKnobInset
            self.numberFieldWidth = numberFieldWidth
            self.numberUnitGap = numberUnitGap
            self.stepper = stepper
            self.stepperGap = stepperGap
            self.stepperArrow = stepperArrow
            self.stepperArrowGap = stepperArrowGap
            self.secureFieldWidth = secureFieldWidth
            self.rowControlGap = rowControlGap
            self.badgeDotGap = badgeDotGap
            self.badgeHeight = badgeHeight
            self.badgePadding = badgePadding
            self.failureDash = failureDash
        }
    }

    /// The Settings window (#162): its width, the tab well, the row area and the Theme
    /// row's chips. Row height is `sizes.formRow`. `SettingsWindowGeometry` adds these
    /// up.
    struct SettingsWindowMetrics: Equatable, Sendable {
        /// The window's width.
        public var width: CGFloat
        /// The text edge of the tab well and the rows.
        public var textEdge: CGFloat
        /// The row area's padding above the first row and below the last.
        public var rowAreaTop: CGFloat
        public var rowAreaBottom: CGFloat
        /// Between two rows.
        public var rowSpacing: CGFloat
        /// The least space between a row's label and its control.
        public var labelSpacing: CGFloat
        /// The tab well band's padding above and below the track.
        public var tabWellPadding: CGFloat
        /// A tab segment's height, the track's padding around the segments and the gap
        /// between them.
        public var tabSegmentHeight: CGFloat
        public var tabTrackPadding: CGFloat
        public var tabSegmentGap: CGFloat
        /// The lines above the tab well and above the rows.
        public var dividerWidth: CGFloat
        /// The Theme chips: icon, icon to name, side padding, selected outline, and the
        /// gap between chips.
        public var chipIcon: CGFloat
        public var chipIconGap: CGFloat
        public var chipPadding: CGFloat
        public var chipSelectedOutline: CGFloat
        public var chipSpacing: CGFloat
        /// Between a control and the error line under it (Launch at login).
        public var errorLineGap: CGFloat
        /// A hint line between two rows (Quick paste's usage hint), fixed so the caption
        /// size of the theme does not change the pane's height.
        public var hintLineHeight: CGFloat

        public init(
            width: CGFloat,
            textEdge: CGFloat,
            rowAreaTop: CGFloat,
            rowAreaBottom: CGFloat,
            rowSpacing: CGFloat,
            labelSpacing: CGFloat,
            tabWellPadding: CGFloat,
            tabSegmentHeight: CGFloat,
            tabTrackPadding: CGFloat,
            tabSegmentGap: CGFloat,
            dividerWidth: CGFloat,
            chipIcon: CGFloat,
            chipIconGap: CGFloat,
            chipPadding: CGFloat,
            chipSelectedOutline: CGFloat,
            chipSpacing: CGFloat,
            errorLineGap: CGFloat,
            hintLineHeight: CGFloat
        ) {
            self.width = width
            self.textEdge = textEdge
            self.rowAreaTop = rowAreaTop
            self.rowAreaBottom = rowAreaBottom
            self.rowSpacing = rowSpacing
            self.labelSpacing = labelSpacing
            self.tabWellPadding = tabWellPadding
            self.tabSegmentHeight = tabSegmentHeight
            self.tabTrackPadding = tabTrackPadding
            self.tabSegmentGap = tabSegmentGap
            self.dividerWidth = dividerWidth
            self.chipIcon = chipIcon
            self.chipIconGap = chipIconGap
            self.chipPadding = chipPadding
            self.chipSelectedOutline = chipSelectedOutline
            self.chipSpacing = chipSpacing
            self.errorLineGap = errorLineGap
            self.hintLineHeight = hintLineHeight
        }
    }
}
