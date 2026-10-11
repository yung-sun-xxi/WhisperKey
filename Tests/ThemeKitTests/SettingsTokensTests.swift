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

    // MARK: - Classic is today's SettingsWindowLayout

    func testClassicSettingsWindowIsTodaysLayout() {
        let window = classic.settingsWindow
        // contentWidth, contentPadding, settingsRowSpacing, settingsRowColumnSpacing
        XCTAssertEqual(window.width, 460)
        XCTAssertEqual(window.rowAreaTop, 18)
        XCTAssertEqual(window.rowAreaBottom, 18)
        XCTAssertEqual(classic.spacing.windowTextEdge, 18)
        XCTAssertEqual(window.rowSpacing, 8)
        XCTAssertEqual(window.labelSpacing, 12)
        // settingsRowHeight, settingsControlHeight
        XCTAssertEqual(classic.sizes.formRow, 24)
        XCTAssertEqual(classic.sizes.control, 22)
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
