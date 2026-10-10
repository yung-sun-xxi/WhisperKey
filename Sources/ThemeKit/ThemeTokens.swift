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
/// each doc comment quotes the sheet's number or usage. Classic holds what the views
/// draw today in that role, so moving a view onto a token changes nothing in Classic.
public struct ThemeTokens: Equatable, Sendable {
    public var theme: AppTheme
    public var colors: Colors
    public var type: TypeScale
    public var radii: Radii
    public var sizes: Sizes
    public var spacing: Spacing
    public var panels: Panels
    public var shadows: Shadows

    public init(
        theme: AppTheme,
        colors: Colors,
        type: TypeScale,
        radii: Radii,
        sizes: Sizes,
        spacing: Spacing,
        panels: Panels,
        shadows: Shadows
    ) {
        self.theme = theme
        self.colors = colors
        self.type = type
        self.radii = radii
        self.sizes = sizes
        self.spacing = spacing
        self.panels = panels
        self.shadows = shadows
    }
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
        /// 02 as well in Midnight. Settings and Reset usage, which Classic paints with
        /// the control background rather than the window background.
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
            offKnob: ThemeColor
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
            checkMark: ThemeFont
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
        /// 40. Form row: Settings.
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
    /// The three floating panels. The sheet gives them one shell (#105 rule 4); Classic
    /// draws each its own way today, so each has its own value.
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
    /// An `NSVisualEffectView` blurring what lies behind the window, as Classic does.
    case material(PanelMaterial)
    /// A colour over a blur of the given radius: Midnight's 02 at 95%, blur 30.
    case fill(ThemeColor, blur: CGFloat)
}

/// The `NSVisualEffectView.Material` a Classic panel uses. Named here so the token stays
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
