import CoreGraphics
import XCTest
@testable import ThemeKit

/// The Settings window's tokens (#162). The themes differ only in colours
/// (`ThemeParityTests`); Midnight is held to the token sheet in `TokenSheetTests`.
final class SettingsTokensTests: XCTestCase {
    private let daylight = ThemeTokens.daylight
    private let midnight = ThemeTokens.midnight

    // MARK: - Window

    /// The appearance follows the palette: Daylight is light, Midnight dark, so the
    /// system's titlebar, menus and alerts match.
    func testEachThemeGivesTheWindowItsPalettesAppearance() {
        XCTAssertEqual(daylight.windowAppearance, .light)
        XCTAssertEqual(midnight.windowAppearance, .dark)
        XCTAssertEqual(WindowAppearance.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(WindowAppearance.light.nsAppearance?.name, .aqua)
    }

    /// 520 wide, rows of 32 back to back, the same row-area padding and text edge.
    func testBothThemesShareTheSettingsWindowsWidthAndRows() {
        for tokens in [daylight, midnight] {
            let window = tokens.settingsWindow
            let theme = tokens.theme.rawValue
            XCTAssertEqual(window.width, 520, theme)
            XCTAssertEqual(tokens.sizes.formRow, 32, theme)
            XCTAssertEqual(window.rowSpacing, 0, theme)
            XCTAssertEqual(window.rowAreaTop, 10, theme)
            XCTAssertEqual(window.rowAreaBottom, 16, theme)
            XCTAssertEqual(window.textEdge, 20, theme)
            XCTAssertEqual(window.hintLineHeight, 16, theme)
            XCTAssertEqual(window.labelSpacing, 12, theme)
        }
        // The Settings edge is the sheet's window edge.
        XCTAssertEqual(midnight.settingsWindow.textEdge, midnight.spacing.windowTextEdge)
    }

    /// The tab well's track metrics.
    func testTheTabTrackMetrics() {
        for tokens in [daylight, midnight] {
            let window = tokens.settingsWindow
            XCTAssertEqual(window.tabSegmentHeight, 26, tokens.theme.rawValue)
            XCTAssertEqual(window.tabTrackPadding, 2, tokens.theme.rawValue)
            XCTAssertEqual(window.tabSegmentGap, 2, tokens.theme.rawValue)
            XCTAssertEqual(window.dividerWidth, 1, tokens.theme.rawValue)
            XCTAssertEqual(window.tabWellPadding, 14, tokens.theme.rawValue)
        }
    }

    /// Every pane — rows 0 to 8, with or without the Quick paste hint — comes out one
    /// content height in both themes.
    func testTheContentIsOneHeightInBothThemes() {
        for rows in 0...8 {
            for hints in 0...1 {
                XCTAssertEqual(
                    SettingsWindowGeometry.contentHeight(daylight, rows: rows, hintLines: hints),
                    SettingsWindowGeometry.contentHeight(midnight, rows: rows, hintLines: hints),
                    "rows \(rows), hints \(hints)"
                )
            }
        }
    }

    /// The sum written out once, for General's four rows: tab well
    /// 1 + 14 + (26 + 2 + 2) + 14 + 1 = 60, rows 10 + 4 × 32 + 16 = 154. The system
    /// titlebar sits above that content.
    func testGeneralContentIsTwoHundredFourteenTall() {
        XCTAssertEqual(SettingsWindowGeometry.tabWellHeight(midnight), 60)
        XCTAssertEqual(SettingsWindowGeometry.headerHeight(midnight), 60)
        XCTAssertEqual(SettingsWindowGeometry.paneHeight(midnight, rows: 4), 154)
        XCTAssertEqual(SettingsWindowGeometry.contentHeight(midnight, rows: 4), 214)
        XCTAssertEqual(SettingsWindowGeometry.contentHeight(daylight, rows: 4), 214)
        // Quick paste on: five rows and the hint line.
        XCTAssertEqual(SettingsWindowGeometry.paneHeight(daylight, rows: 5, hintLines: 1), 202)
    }

    /// The Theme chips keep the app's earlier sizes at the control height.
    func testThemePickerChipSizes() {
        let window = midnight.settingsWindow
        XCTAssertEqual(window.chipIcon, 20)
        XCTAssertEqual(window.chipIconGap, 5)
        XCTAssertEqual(window.chipPadding, 6)
        XCTAssertEqual(window.chipSelectedOutline, 2)
        XCTAssertEqual(window.chipSpacing, 8)
        XCTAssertEqual(window.errorLineGap, 4)
        XCTAssertEqual(midnight.radii.control, 6)
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
