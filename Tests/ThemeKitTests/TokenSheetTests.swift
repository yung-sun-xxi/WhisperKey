import CoreGraphics
import Foundation
import XCTest
@testable import ThemeKit

/// Midnight against `docs/design/tokens.md`, read from the file itself, so a change to
/// the sheet that the tokens do not follow turns this red. Daylight's colours are held to
/// the sheet's "Daylight" column the same way, in `DaylightTokenSheetTests` below.
final class TokenSheetTests: XCTestCase {
    private var sheet: TokenSheet!
    private let midnight = ThemeTokens.midnight

    override func setUpWithError() throws {
        sheet = try TokenSheet.load()
    }

    // MARK: - Colours

    func testGreysMatchTheSheet() throws {
        let colors = midnight.colors
        XCTAssertEqual(colors.bar, .hex(try sheet.hex("01")))
        XCTAssertEqual(colors.surface, .hex(try sheet.hex("02")))
        XCTAssertEqual(colors.settingsSurface, .hex(try sheet.hex("02")))
        XCTAssertEqual(colors.card, .hex(try sheet.hex("03")))
        XCTAssertEqual(colors.divider, .hex(try sheet.hex("03")))
        XCTAssertEqual(colors.selectedRow, .hex(try sheet.hex("04")))
        XCTAssertEqual(colors.raisedControl, .hex(try sheet.hex("04")))
        XCTAssertEqual(colors.edge, .hex(try sheet.hex("05")))
        XCTAssertEqual(colors.mutedEdge, .hex(try sheet.hex("06")))
        XCTAssertEqual(colors.secondaryText, .hex(try sheet.hex("07")))
        XCTAssertEqual(colors.navigationText, .hex(try sheet.hex("07n")))
        XCTAssertEqual(colors.primaryText, .hex(try sheet.hex("08")))
        XCTAssertEqual(colors.checkboxFill, .hex(try sheet.hex("08")))
    }

    func testBrandAndStateColoursMatchTheSheet() throws {
        let colors = midnight.colors
        XCTAssertEqual(colors.brand, .hex(try sheet.hex("red")))
        XCTAssertEqual(colors.brandHover, .hex(try sheet.hex("red hover")))
        XCTAssertEqual(colors.onBrand, .hex(try sheet.hex("on red")))
        XCTAssertEqual(colors.recordingStop, .hex(try sheet.hex("red")))
        XCTAssertEqual(colors.success, .hex(try sheet.hex("green")))
        XCTAssertEqual(colors.offKnob, .hex(try sheet.hex("off knob")))

        // "hatch `#8A909E` at 18% on `#1E2126`"
        let failure = try sheet.hexes("failure")
        XCTAssertEqual(failure.count, 2)
        XCTAssertEqual(colors.failureHatch, .hex(failure[0], opacity: 0.18))
        XCTAssertEqual(colors.failureFill, .hex(failure[1]))
    }

    /// The system red is macOS's, drawn in alerts, and never a WhisperKey token.
    func testNoTokenIsTheSystemRed() throws {
        let systemRed = try sheet.hex("system red")
        let mirror = Mirror(reflecting: midnight.colors)
        for child in mirror.children {
            XCTAssertNotEqual(child.value as? ThemeColor, .hex(systemRed), child.label ?? "")
        }
    }

    // MARK: - Type

    func testTypeMatchesTheSheet() throws {
        let type = midnight.type
        XCTAssertEqual(try sheet.font(usage: "stat values"), font(type.statValue))
        XCTAssertTrue(type.statValue.tabularDigits, "stat values are tabular")
        XCTAssertEqual(try sheet.font(usage: "window title"), font(type.title))
        XCTAssertEqual(try sheet.font(usage: "row labels"), font(type.body))
        XCTAssertEqual(try sheet.font(usage: "status line"), font(type.small))
        XCTAssertEqual(try sheet.font(usage: "timestamps"), font(type.caption))
        XCTAssertEqual(try sheet.font(usage: "caps headers"), font(type.capsHeader))
        XCTAssertEqual(type.capsHeader.trackingEm, 0.06, accuracy: 0.0001)
        XCTAssertEqual(type.bodyLineHeight ?? 0, try sheet.number(after: "Body line-height"), accuracy: 0.0001)
        // "Default button: red fill, 13/500 on-red label"
        XCTAssertEqual(try sheet.fontInText(after: "**Default button**"), font(type.defaultButton))
    }

    /// The values the surfaces use and the sheet does not list (its section 2 and 3).
    func testTypeGapsMatchTheMockups() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        let type = midnight.type
        XCTAssertTrue(gaps.contains("(\"All\") is 11/500"))
        XCTAssertEqual(font(type.segmentLabelOnBrand), FontSpec(size: 11, weight: 500))
        XCTAssertTrue(gaps.contains("\"Hold\" segment are 12/500"))
        XCTAssertEqual(font(type.labelOnBrand), FontSpec(size: 12, weight: 500))
        XCTAssertTrue(gaps.contains("is 10/700"))
        XCTAssertEqual(font(type.checkMark), FontSpec(size: 10, weight: 700))
    }

    // MARK: - Radii, sizes, spacing

    func testRadiiMatchTheSheet() throws {
        let radii = midnight.radii
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "window shell"), radii.window)
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "rows, cards"), radii.card)
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "rows, cards"), radii.row)
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "rows, cards"), radii.toggle)
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "keycaps, fields"), radii.control)
        XCTAssertEqual(try sheet.firstColumnNumber(usage: "checkbox"), radii.checkbox)
        for panel in [midnight.panels.popover, midnight.panels.quickPaste, midnight.panels.toast] {
            XCTAssertEqual(try sheet.firstColumnNumber(usage: "panel shell"), panel.radius)
        }
    }

    func testSizesMatchTheSheet() throws {
        let sizes = midnight.sizes
        XCTAssertEqual(try sheet.size("list row"), sizes.listRow)
        XCTAssertEqual(try sheet.size("form row"), sizes.formRow)
        XCTAssertEqual(try sheet.size("panel bar"), sizes.panelBar)
        XCTAssertEqual(try sheet.size("titlebar"), sizes.titlebar)
        XCTAssertEqual(try sheet.size("+ action bar"), sizes.actionBar)
        XCTAssertEqual(try sheet.size("menu item"), sizes.menuItem)
        XCTAssertEqual(try sheet.size("control"), sizes.control)
        XCTAssertEqual(try sheet.size("keycap, badge"), sizes.keycap)
        XCTAssertEqual(try sheet.sizePair("toggle"), sizes.toggle)
        XCTAssertEqual(try sheet.size("+ checkbox"), sizes.checkbox)
        XCTAssertEqual(try sheet.size("dot"), sizes.dot)
        XCTAssertEqual(try sheet.sizePair("bar"), sizes.selectionBar)

        let widths = try sheet.cell(firstColumn: "widths", column: 1)
        XCTAssertTrue(widths.contains("panel \(Int(midnight.panels.popover.width))"), widths)
        XCTAssertTrue(widths.contains("quick paste \(Int(midnight.panels.quickPaste.width))"), widths)
        XCTAssertTrue(widths.contains("toast \(Int(midnight.panels.toast.width))"), widths)
    }

    func testSegmentSizesMatchTheMockups() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        let sizes = midnight.sizes
        XCTAssertTrue(gaps.contains("segments are \(Int(sizes.periodSegment)) tall in a \(Int(sizes.periodTrack)) track"), gaps)
        XCTAssertTrue(gaps.contains("segments are \(Int(sizes.modeSegment)) tall at radius \(Int(midnight.radii.modeSegment)) in a \(Int(sizes.modeTrack)) track"), gaps)
    }

    func testSpacingMatchesTheSheet() throws {
        let spacing = midnight.spacing
        XCTAssertEqual(try sheet.spacingSteps(), spacing.steps)
        let edges = try sheet.section("Spacing and edges")
        XCTAssertTrue(edges.contains("Text edge \(Int(spacing.panelTextEdge)) in panels, \(Int(spacing.windowTextEdge)) in windows"), edges)
        XCTAssertTrue(edges.contains("Rows inset \(Int(spacing.rowInset)) from the shell with \(Int(spacing.rowPadding)) inside"), edges)
        let popover = midnight.popover
        XCTAssertTrue(edges.contains("Stat tile inset \(Int(popover.statInsetVertical))×\(Int(popover.statInsetHorizontal))"), edges)
    }

    // MARK: - Settings window (#162)

    /// Item 10 of the gaps list: the window, the tab well and the row area.
    func testSettingsWindowMatchesTheMockups() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        let window = midnight.settingsWindow
        XCTAssertTrue(gaps.contains("The window is \(n(window.width)) wide, its edge included"), gaps)
        // "+ settings window | 520 | Settings, both themes".
        XCTAssertEqual(window.width, try sheet.size("+ settings window"))
        XCTAssertTrue(try sheet.cell(firstColumn: "settings window", column: 2).contains("both themes"))
        XCTAssertEqual(ThemeTokens.daylight.settingsWindow.width, try sheet.size("+ settings window"))
        XCTAssertTrue(gaps.contains("The tab well band is padded \(n(window.tabWellPadding)) above and below, its track padded \(n(window.tabTrackPadding)) with a \(n(window.tabSegmentGap)) gap between segments \(n(window.tabSegmentHeight)) tall"), gaps)
        XCTAssertTrue(gaps.contains("The row area is padded \(n(window.rowAreaTop)) at the top and \(n(window.rowAreaBottom)) at the bottom"), gaps)
        // Rows are the sheet's form row, back to back, at the window text edge.
        XCTAssertEqual(midnight.sizes.formRow, try sheet.size("form row"))
        XCTAssertEqual(window.rowSpacing, 0)
        XCTAssertTrue(try sheet.section("Spacing and edges").contains("\(n(midnight.spacing.windowTextEdge)) in windows"))
        // "01 bars: ... titlebar, tab well"; "03 ... Dividers on 02".
        XCTAssertTrue(try sheet.cell(firstColumn: "01", column: 2).contains("tab well"))
        XCTAssertEqual(midnight.colors.bar, .hex(try sheet.hex("01")))
        XCTAssertEqual(midnight.colors.divider, .hex(try sheet.hex("03")))
        XCTAssertEqual(window.dividerWidth, 1)
    }

    /// Item 11 of the gaps list: the reusable controls.
    func testSettingsControlsMatchTheMockups() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        let controls = midnight.controlMetrics
        let sizes = midnight.sizes
        XCTAssertTrue(gaps.contains("Push button: a \(n(sizes.control - 2 * controls.edgeWidth)) line inside a \(n(controls.edgeWidth))px 05 edge, padded \(n(controls.horizontalPadding))"), gaps)
        XCTAssertTrue(gaps.contains("Pop-up: min width \(n(controls.popUpMinWidth)), padded \(n(controls.horizontalPadding)), a \(n(controls.popUpTitleGap)) gap before up and down chevrons of \(n(controls.popUpChevron)) with a \(n(controls.popUpChevronGap)) gap"), gaps)
        XCTAssertTrue(gaps.contains("Segmented control: \(n(controls.segmentedWidth)) wide"), gaps)
        XCTAssertTrue(gaps.contains("Number field: padded \(n(controls.horizontalPadding)), an \(n(controls.numberUnitGap)) gap before the unit, then a \(n(controls.stepper.width))×\(n(controls.stepper.height)) stepper \(n(controls.stepperGap)) apart with triangles of \(n(controls.stepperArrow)), \(n(controls.stepperArrowGap)) apart"), gaps)
        XCTAssertTrue(gaps.contains("Toggle knob \(n(controls.toggleKnob)), inset \(n(controls.toggleKnobInset))"), gaps)
        XCTAssertTrue(gaps.contains("API key field \(n(controls.secureFieldWidth)) wide, an \(n(controls.rowControlGap)) gap between the row's controls"), gaps)
        XCTAssertTrue(gaps.contains("Saved badge: a \(n(controls.badgeDotGap)) gap after the dot"), gaps)
        XCTAssertTrue(gaps.contains("Rejected badge: a \(n(controls.badgeHeight)) line padded \(n(controls.badgePadding)) in a \(n(controls.edgeWidth))px dashed 06 edge"), gaps)
        XCTAssertFalse(controls.failureDash.isEmpty, "a dashed edge needs a dash pattern")

        // The knob fills the toggle's height less its inset on both sides.
        XCTAssertEqual(controls.toggleKnob + 2 * controls.toggleKnobInset, sizes.toggle.height)
        // The segmented control is the sheet's "Hold / Toggle" track and segment.
        XCTAssertEqual(sizes.modeSegment + 2 * controls.trackPadding, sizes.modeTrack)
        // The stepper is as tall as a control.
        XCTAssertEqual(controls.stepper.height, try sheet.size("control"))
    }

    private func n(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(Double(value))
    }

    // MARK: - Panels and shadows

    func testShadowsMatchTheMockups() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        // The sheet states a drawn panel shadow; the panels keep the window server's
        // instead (#161, the owner's decision: a drawn one needs a larger window whose
        // shadow would catch clicks).
        XCTAssertEqual(try TokenSheet.shadow(in: gaps, after: "panels"), .drop(color: .hex(0x000000, opacity: 0.5), blur: 48, x: 0, y: 22))
        XCTAssertEqual(midnight.panels.popover.shadow, .system)
        XCTAssertEqual(midnight.panels.quickPaste.shadow, .system)
        XCTAssertEqual(midnight.panels.toast.shadow, .system)
        XCTAssertEqual(midnight.shadows.window, try TokenSheet.shadow(in: gaps, after: "windows"))
        XCTAssertEqual(midnight.shadows.menu, try TokenSheet.shadow(in: gaps, after: "actions menu"))
        XCTAssertEqual(midnight.shadows.alert, try TokenSheet.shadow(in: gaps, after: "the mock alert"))
    }

    /// "02 surface. Panels at 95% + blur 30", edged in 05 ("every edge: shell").
    func testPanelShellsAreOneShell() throws {
        let surface = try sheet.hex("02")
        let edge = try sheet.hex("05")
        for panel in [midnight.panels.popover, midnight.panels.quickPaste, midnight.panels.toast] {
            XCTAssertEqual(panel.background, .fill(.hex(surface, opacity: 0.95), blur: 30))
            XCTAssertEqual(panel.edge, .hex(edge))
            XCTAssertEqual(panel.edgeWidth, 1)
        }
        let usage = try sheet.cell(firstColumn: "02", column: 2)
        XCTAssertTrue(usage.contains("Panels at 95% + blur 30"), usage)
    }

    private func font(_ font: ThemeFont) -> FontSpec {
        FontSpec(size: font.size, weight: font.weight.rawValue)
    }
}

// MARK: - Daylight

/// Daylight against the sheet's "Daylight" column (#176): every colour role takes the
/// Daylight value of the token Midnight's role uses, so the two palettes cannot drift
/// apart in which token a role means.
final class DaylightTokenSheetTests: XCTestCase {
    private var sheet: TokenSheet!
    private let daylight = ThemeTokens.daylight
    private let midnight = ThemeTokens.midnight

    override func setUpWithError() throws {
        sheet = try TokenSheet.load()
    }

    /// The sheet token of each colour role, as `ThemeTokens+Midnight.swift` names it.
    private let roles: [(String, KeyPath<ThemeTokens.Colors, ThemeColor>, String)] = [
        ("bar", \.bar, "01"),
        ("surface", \.surface, "02"),
        ("settingsSurface", \.settingsSurface, "02"),
        ("card", \.card, "03"),
        ("divider", \.divider, "03"),
        ("selectedRow", \.selectedRow, "04"),
        ("raisedControl", \.raisedControl, "04"),
        ("edge", \.edge, "05"),
        ("mutedEdge", \.mutedEdge, "06"),
        ("secondaryText", \.secondaryText, "07"),
        ("navigationText", \.navigationText, "07n"),
        ("primaryText", \.primaryText, "08"),
        ("checkboxFill", \.checkboxFill, "08"),
        ("brand", \.brand, "red"),
        ("brandHover", \.brandHover, "red hover"),
        ("onBrand", \.onBrand, "on red"),
        ("recordingStop", \.recordingStop, "red"),
        ("success", \.success, "green"),
        ("offKnob", \.offKnob, "off knob"),
        ("destructiveText", \.destructiveText, "08"),
        ("destructiveGlyph", \.destructiveGlyph, "07"),
        ("failureText", \.failureText, "08"),
        ("cautionText", \.cautionText, "07"),
        ("actionGlyph", \.actionGlyph, "07"),
        ("chipEdge", \.chipEdge, "05"),
    ]

    func testEveryColourRoleTakesItsTokensDaylightValue() throws {
        for (name, role, token) in roles {
            XCTAssertEqual(midnight.colors[keyPath: role], .hex(try sheet.hex(token)), "Midnight \(name) is \(token)")
            XCTAssertEqual(daylight.colors[keyPath: role], .hex(try sheet.hex(token, .daylight)), "Daylight \(name) is \(token)")
        }
        // "hatch `#666C78` at 18% on `#E8E9ED`"
        let failure = try sheet.hexes("failure", .daylight)
        XCTAssertEqual(failure.count, 2)
        XCTAssertEqual(daylight.colors.failureHatch, .hex(failure[0], opacity: 0.18))
        XCTAssertEqual(daylight.colors.failureFill, .hex(failure[1]))
    }

    /// The table above covers every role, so a role added later must be placed on the
    /// sheet before this passes.
    func testTheRoleTableCoversEveryColour() {
        let named = Set(roles.map(\.0)).union(["failureFill", "failureHatch"])
        let all = Set(Mirror(reflecting: daylight.colors).children.compactMap(\.label))
        XCTAssertEqual(all, named)
    }

    func testNoTokenIsTheSystemRed() throws {
        let systemRed = try sheet.hex("system red", .daylight)
        for child in Mirror(reflecting: daylight.colors).children {
            XCTAssertNotEqual(child.value as? ThemeColor, .hex(systemRed), child.label ?? "")
        }
    }

    /// "02 surface. Panels at 95% + blur 30", edged in 05: Daylight's 02 and 05.
    func testPanelShellsAreOneShellInDaylightsColours() throws {
        let surface = try sheet.hex("02", .daylight)
        let edge = try sheet.hex("05", .daylight)
        XCTAssertTrue(try sheet.cell(firstColumn: "02", column: 3).contains("Panels at 95%"))
        for panel in [daylight.panels.popover, daylight.panels.quickPaste, daylight.panels.toast] {
            XCTAssertEqual(panel.background, .fill(.hex(surface, opacity: 0.95), blur: 30))
            XCTAssertEqual(panel.edge, .hex(edge))
            XCTAssertEqual(panel.shadow, .system)
        }
    }

    func testShadowsMatchTheLightDesign() throws {
        let gaps = try sheet.section("Values the surfaces use that the sheet does not list")
        XCTAssertEqual(try TokenSheet.shadow(in: gaps, after: "light panels"), .drop(color: .hex(0x000000, opacity: 0.16), blur: 48, x: 0, y: 22))
        XCTAssertEqual(daylight.shadows.window, try TokenSheet.shadow(in: gaps, after: "light windows"))
        XCTAssertEqual(daylight.shadows.menu, try TokenSheet.shadow(in: gaps, after: "light actions menu"))
        XCTAssertEqual(daylight.shadows.alert, try TokenSheet.shadow(in: gaps, after: "light mock alert"))
        // The app's own close disc is in neither design and keeps Midnight's shadow.
        XCTAssertEqual(daylight.shadows.closeButton, midnight.shadows.closeButton)
    }
}

// MARK: - Reading the sheet

struct FontSpec: Equatable, CustomStringConvertible {
    let size: CGFloat
    let weight: Int
    var description: String { "\(Int(size))/\(weight)" }
}

/// Just enough of a reader for `docs/design/tokens.md`: its tables, sections and the
/// shadow strings. Every lookup throws when the sheet does not say what it looks for,
/// so a renamed row fails loudly instead of matching nothing.
struct TokenSheet {
    struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "tokens.md has no \(what)" }
    }

    let text: String
    /// Every table row, as trimmed cells with backticks removed.
    let rows: [[String]]

    static func load() throws -> TokenSheet {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ThemeKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository
            .appendingPathComponent("docs/design/tokens.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.split(separator: "\n").compactMap { line -> [String]? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), !trimmed.hasPrefix("|---") else { return nil }
            return trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst()
                .dropLast()
                .map { $0.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return TokenSheet(text: text, rows: rows)
    }

    func cell(firstColumn key: String, column: Int) throws -> String {
        guard let row = rows.first(where: { $0.first == key || $0.first == "+ \(key)" }), row.count > column else {
            throw Missing(what: "row \"\(key)\"")
        }
        return row[column]
    }

    /// The colour tables' columns: Midnight's value is the second, Daylight's the fourth
    /// (after the usage, so the usage stays the third column for every reader).
    enum Palette: Int {
        case midnight = 1
        case daylight = 3
    }

    func hex(_ key: String, _ palette: Palette = .midnight) throws -> UInt32 {
        let values = try hexes(key, palette)
        guard values.count == 1 else { throw Missing(what: "single \(palette) hex for \"\(key)\"") }
        return values[0]
    }

    func hexes(_ key: String, _ palette: Palette = .midnight) throws -> [UInt32] {
        let value = try cell(firstColumn: key, column: palette.rawValue)
        let values = Self.matches(of: "#([0-9A-Fa-f]{6})", in: value).compactMap { UInt32($0[1], radix: 16) }
        guard !values.isEmpty else { throw Missing(what: "\(palette) hex for \"\(key)\"") }
        return values
    }

    /// The type table: the row whose usage starts with `usage`, read as "15/600".
    func font(usage: String) throws -> FontSpec {
        guard let row = rows.first(where: { $0.count >= 3 && $0[2].lowercased().hasPrefix(usage.lowercased()) }) else {
            throw Missing(what: "type row for \"\(usage)\"")
        }
        return try Self.font(in: row[0])
    }

    func fontInText(after marker: String) throws -> FontSpec {
        guard let range = text.range(of: marker) else { throw Missing(what: marker) }
        let line = text[range.upperBound...].prefix { $0 != "\n" }
        return try Self.font(in: String(line))
    }

    static func font(in text: String) throws -> FontSpec {
        guard let match = matches(of: "([0-9]+)/([0-9]{3})", in: text).first,
              let size = Double(match[1]), let weight = Int(match[2]) else {
            throw Missing(what: "size/weight in \"\(text)\"")
        }
        return FontSpec(size: CGFloat(size), weight: weight)
    }

    /// The radii table: the number in the first column of the row whose usage starts
    /// with `usage`.
    func firstColumnNumber(usage: String) throws -> CGFloat {
        guard let row = rows.first(where: { $0.count == 2 && $0[1].lowercased().hasPrefix(usage.lowercased()) }),
              let value = Double(row[0].replacingOccurrences(of: "+ ", with: "")) else {
            throw Missing(what: "radius row for \"\(usage)\"")
        }
        return CGFloat(value)
    }

    /// The sizes table: the "Size" column of a named row.
    func size(_ name: String) throws -> CGFloat {
        guard let row = rows.first(where: { $0.count == 3 && $0[0] == name }), let value = Double(row[1]) else {
            throw Missing(what: "size row \"\(name)\"")
        }
        return CGFloat(value)
    }

    func sizePair(_ name: String) throws -> CGSize {
        guard let row = rows.first(where: { $0.count == 3 && $0[0] == name }) else {
            throw Missing(what: "size row \"\(name)\"")
        }
        let parts = row[1].split(separator: "×").compactMap { Double($0) }
        guard parts.count == 2 else { throw Missing(what: "W×H in \"\(row[1])\"") }
        return CGSize(width: parts[0], height: parts[1])
    }

    func number(after marker: String) throws -> Double {
        guard let range = text.range(of: marker),
              let match = Self.matches(of: "([0-9]+(\\.[0-9]+)?)", in: String(text[range.upperBound...].prefix(20))).first,
              let value = Double(match[1]) else {
            throw Missing(what: "number after \"\(marker)\"")
        }
        return value
    }

    /// "Steps: **2, 3, 4, ...**."
    func spacingSteps() throws -> [CGFloat] {
        guard let match = Self.matches(of: "Steps: \\*\\*([0-9, ]+)\\*\\*", in: text).first else {
            throw Missing(what: "spacing steps")
        }
        return match[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
    }

    /// The text of a `##` section, up to the next one.
    func section(_ heading: String) throws -> String {
        guard let start = text.range(of: "## \(heading)") else { throw Missing(what: "section \"\(heading)\"") }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        // Line breaks inside a paragraph are not meaningful; joining them lets a phrase
        // that wraps in the file still be found.
        return String(rest[..<end]).replacingOccurrences(of: "\n   ", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// The shadow that follows `label` in the gaps list, e.g.
    /// "panels `0 22px 48px rgba(0,0,0,0.5)`".
    static func shadow(in text: String, after label: String) throws -> ThemeShadow {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label)) `([0-9]+)(px)? ([0-9]+)px ([0-9]+)px rgba\\(0,0,0,([0-9.]+)\\)`"
        guard let match = matches(of: pattern, in: text).first,
              let x = Double(match[1]), let y = Double(match[3]), let blur = Double(match[4]), let alpha = Double(match[5]) else {
            throw Missing(what: "shadow after \"\(label)\"")
        }
        return .drop(color: .hex(0x000000, opacity: alpha), blur: CGFloat(blur), x: CGFloat(x), y: CGFloat(y))
    }

    static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
