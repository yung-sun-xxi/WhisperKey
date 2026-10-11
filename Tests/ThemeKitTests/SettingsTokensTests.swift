import CoreGraphics
import XCTest
@testable import ThemeKit

/// The Settings window's tokens (#162): Classic holds what the window draws today, so the
/// move onto tokens changes nothing there; Midnight is held to the token sheet in
/// `TokenSheetTests`.
final class SettingsTokensTests: XCTestCase {
    private let classic = ThemeTokens.classic
    private let midnight = ThemeTokens.midnight

    // MARK: - Rendering

    func testClassicLeavesControlsAndChromeToTheSystem() {
        XCTAssertEqual(classic.controls, .system)
        XCTAssertEqual(classic.windowChrome, .system)
    }

    func testMidnightDrawsControlsAndChromeFromTokens() {
        XCTAssertEqual(midnight.controls, .drawn)
        XCTAssertEqual(midnight.windowChrome, .drawn)
    }

    // MARK: - One window in both themes (decided 2026-10-11)

    /// 520 wide, rows of 32 back to back, the same row-area padding and text edge.
    func testBothThemesShareTheSettingsWindowsWidthAndRows() {
        for tokens in [classic, midnight] {
            let window = tokens.settingsWindow
            let theme = tokens.theme.rawValue
            XCTAssertEqual(window.width, 520, theme)
            XCTAssertEqual(tokens.sizes.formRow, 32, theme)
            XCTAssertEqual(window.rowSpacing, 0, theme)
            XCTAssertEqual(window.rowAreaTop, 10, theme)
            XCTAssertEqual(window.rowAreaBottom, 16, theme)
            XCTAssertEqual(window.textEdge, 20, theme)
            XCTAssertEqual(window.hintLineHeight, 16, theme)
        }
        // Midnight's Settings edge is the sheet's window edge; Classic's general window
        // edge stays SettingsWindowLayout.contentPadding for its other windows.
        XCTAssertEqual(midnight.settingsWindow.textEdge, midnight.spacing.windowTextEdge)
        XCTAssertEqual(classic.spacing.windowTextEdge, 18)
        XCTAssertEqual(classic.settingsWindow.labelSpacing, 12)
    }

    /// Classic keeps the system's controls at their size, centred in the taller row.
    func testClassicControlsStayTheSystemsSize() {
        XCTAssertEqual(classic.sizes.control, 22)
        XCTAssertLessThan(classic.sizes.control, classic.sizes.formRow)
    }

    /// Classic's tab well is Midnight's track in Classic's colours and radii.
    func testClassicTabTrackHasMidnightsMetrics() {
        for tokens in [classic, midnight] {
            let window = tokens.settingsWindow
            XCTAssertEqual(window.tabSegmentHeight, 26, tokens.theme.rawValue)
            XCTAssertEqual(window.tabTrackPadding, 2, tokens.theme.rawValue)
            XCTAssertEqual(window.tabSegmentGap, 2, tokens.theme.rawValue)
            XCTAssertEqual(window.dividerWidth, 1, tokens.theme.rawValue)
        }
        XCTAssertNotEqual(classic.radii.card, midnight.radii.card)
        XCTAssertEqual(classic.colors.brand, .system(.accent))
    }

    /// Classic's band is taller by half the difference between Midnight's drawn bar and
    /// Classic's titlebar band, above and below, so both headers end at the same height.
    func testClassicBandMakesUpTheSystemTitlebar() {
        // The system titlebar, measured on macOS 27.0.1: a titled window's frame less its
        // content rect. Classic's band holds its place under the transparent titlebar.
        XCTAssertEqual(classic.sizes.titlebar, 32)
        XCTAssertEqual(
            classic.settingsWindow.tabWellPadding,
            midnight.settingsWindow.tabWellPadding + (midnight.sizes.titlebar - classic.sizes.titlebar) / 2
        )
        XCTAssertEqual(
            SettingsWindowGeometry.headerHeight(classic),
            SettingsWindowGeometry.headerHeight(midnight)
        )
    }

    /// Every pane — rows 3 to 6, with or without the Quick paste hint — comes out one
    /// frame in both themes.
    func testTheWindowIsOneHeightInBothThemes() {
        for rows in 0...8 {
            for hints in 0...1 {
                XCTAssertEqual(
                    SettingsWindowGeometry.frameHeight(classic, rows: rows, hintLines: hints),
                    SettingsWindowGeometry.frameHeight(midnight, rows: rows, hintLines: hints),
                    "rows \(rows), hints \(hints)"
                )
                XCTAssertEqual(
                    SettingsWindowGeometry.frameHeight(classic, rows: rows, hintLines: hints),
                    SettingsWindowGeometry.contentHeight(classic, rows: rows, hintLines: hints),
                    "the frame is the content, rows \(rows), hints \(hints)"
                )
            }
        }
    }

    /// The sum written out once, for General's four rows: Midnight's titlebar 44, tab well
    /// 1 + 14 + (26 + 2 + 2) + 14 + 1 = 60; Classic's band 32, tab well
    /// 1 + 20 + 30 + 20 + 1 = 72; rows 10 + 4 × 32 + 16 = 154 in both.
    func testGeneralIsTwoHundredFiftyEightTall() {
        XCTAssertEqual(SettingsWindowGeometry.tabWellHeight(midnight), 60)
        XCTAssertEqual(SettingsWindowGeometry.headerHeight(midnight), 104)
        XCTAssertEqual(SettingsWindowGeometry.tabWellHeight(classic), 72)
        XCTAssertEqual(SettingsWindowGeometry.headerHeight(classic), 104)
        XCTAssertEqual(SettingsWindowGeometry.paneHeight(midnight, rows: 4), 154)
        XCTAssertEqual(SettingsWindowGeometry.frameHeight(midnight, rows: 4), 258)
        XCTAssertEqual(SettingsWindowGeometry.frameHeight(classic, rows: 4), 258)
        XCTAssertEqual(SettingsWindowGeometry.contentHeight(classic, rows: 4), 258)
        // Quick paste on: five rows and the hint line.
        XCTAssertEqual(SettingsWindowGeometry.paneHeight(classic, rows: 5, hintLines: 1), 202)
    }

    func testClassicThemePickerIsTodaysChip() {
        let window = classic.settingsWindow
        XCTAssertEqual(window.chipIcon, 20)
        XCTAssertEqual(window.chipIconGap, 5)
        XCTAssertEqual(window.chipPadding, 6)
        XCTAssertEqual(window.chipSelectedOutline, 2)
        XCTAssertEqual(window.chipSpacing, 8)
        XCTAssertEqual(window.errorLineGap, 4)
        XCTAssertEqual(classic.colors.chipEdge, .system(.primary, opacity: 0.15))
        XCTAssertEqual(classic.radii.control, 6)
    }

    func testClassicControlsAreTodaysSizes() {
        let controls = classic.controlMetrics
        // The rounded-border number fields and the API key field.
        XCTAssertEqual(controls.numberFieldWidth, 64)
        XCTAssertEqual(controls.secureFieldWidth, 108)
        // HStack(spacing: 6) in the number rows and the API key row.
        XCTAssertEqual(controls.numberUnitGap, 6)
        XCTAssertEqual(controls.stepperGap, 6)
        XCTAssertEqual(controls.rowControlGap, 6)
        // The API key badge's minimum height: settingsControlHeight.
        XCTAssertEqual(controls.badgeHeight, 22)
        // settingsActionIconSize, semibold.
        XCTAssertEqual(classic.type.actionGlyph, ThemeFont(size: 14, weight: .semibold))
        // `.caption` and `.caption2` on macOS: 10pt regular.
        XCTAssertEqual(classic.type.fieldCaption, ThemeFont(size: 10, weight: .regular))
    }

    /// The colours the Settings rows draw today in Classic: red Reset usage and trash,
    /// red "Invalid key" and Launch at login error, orange "Not verified", primary shield.
    func testClassicSettingsColoursAreTodays() {
        let colors = classic.colors
        XCTAssertEqual(colors.destructiveText, .system(.red))
        XCTAssertEqual(colors.destructiveGlyph, .system(.red))
        XCTAssertEqual(colors.failureText, .system(.red))
        XCTAssertEqual(colors.cautionText, .system(.orange))
        XCTAssertEqual(colors.actionGlyph, .system(.primary))
        XCTAssertEqual(colors.success, .system(.green))
        XCTAssertEqual(colors.settingsSurface, .system(.controlBackground))
    }

    /// #105 rule 2: no destructive action and no failure is red on a Midnight surface.
    func testMidnightDrawsNoRedOutsideTheBrand() {
        let colors = midnight.colors
        XCTAssertEqual(colors.destructiveText, colors.primaryText)
        XCTAssertEqual(colors.destructiveGlyph, colors.secondaryText)
        XCTAssertEqual(colors.failureText, colors.primaryText)
        XCTAssertEqual(colors.cautionText, colors.secondaryText)
        XCTAssertEqual(colors.actionGlyph, colors.secondaryText)
        XCTAssertEqual(colors.chipEdge, colors.edge)
        XCTAssertEqual(midnight.type.fieldCaption, midnight.type.caption)
    }

    // MARK: - Stepper

    func testAStepMovesByTheStepInsideTheRange() {
        XCTAssertEqual(SteppedValue.next(from: 300, direction: .up, step: 50, range: 200...2000), 350)
        XCTAssertEqual(SteppedValue.next(from: 300, direction: .down, step: 50, range: 200...2000), 250)
        XCTAssertEqual(SteppedValue.next(from: 5, direction: .up, step: 1, range: 1...10), 6)
    }

    func testAStepStopsAtTheEdgesOfTheRange() {
        XCTAssertEqual(SteppedValue.next(from: 1980, direction: .up, step: 50, range: 200...2000), 2000)
        XCTAssertEqual(SteppedValue.next(from: 2000, direction: .up, step: 50, range: 200...2000), 2000)
        XCTAssertEqual(SteppedValue.next(from: 210, direction: .down, step: 50, range: 200...2000), 200)
        XCTAssertEqual(SteppedValue.next(from: 0, direction: .down, step: 1, range: 0...1000), 0)
    }

    func testAValueOutsideTheRangeStepsBackIntoIt() {
        XCTAssertEqual(SteppedValue.next(from: 5000, direction: .up, step: 1, range: 0...1000), 1000)
        XCTAssertEqual(SteppedValue.next(from: -3, direction: .up, step: 1, range: 0...1000), 0)
    }

    func testTheStepperCanStepOnlyWhereTheValueCanMove() {
        XCTAssertFalse(SteppedValue.canStep(from: 2000, direction: .up, range: 200...2000))
        XCTAssertTrue(SteppedValue.canStep(from: 2000, direction: .down, range: 200...2000))
        XCTAssertFalse(SteppedValue.canStep(from: 0, direction: .down, range: 0...1000))
    }

    // MARK: - Tab well

    func testATabIdentifierMapsToItsIndex() {
        let identifiers = ["general", "recording", "transcription", "quickPaste"]
        XCTAssertEqual(TabWellSelection.index(of: "general", in: identifiers), 0)
        XCTAssertEqual(TabWellSelection.index(of: "quickPaste", in: identifiers), 3)
        XCTAssertNil(TabWellSelection.index(of: "missing", in: identifiers))
    }

    func testASelectedIndexStaysInsideTheTabs() {
        XCTAssertEqual(TabWellSelection.clamped(2, count: 4), 2)
        XCTAssertEqual(TabWellSelection.clamped(7, count: 4), 3)
        XCTAssertEqual(TabWellSelection.clamped(-1, count: 4), 0)
        XCTAssertEqual(TabWellSelection.clamped(3, count: 0), 0)
    }
}
