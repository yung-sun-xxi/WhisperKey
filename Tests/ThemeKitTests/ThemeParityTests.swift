import XCTest
@testable import ThemeKit

/// The themes differ only in colours (decided 2026-10-11): one layout, one set of
/// controls, one window chrome. A second palette may change any colour and nothing else,
/// except the window appearance, which follows the palette (#176).
final class ThemeParityTests: XCTestCase {
    private let daylight = ThemeTokens.daylight
    private let midnight = ThemeTokens.midnight

    /// A theme's tokens with every colour set to one value, so only the shape is left.
    private func shape(_ tokens: ThemeTokens) -> ThemeTokens {
        var tokens = tokens
        tokens.theme = .midnight
        tokens.colors = ThemeTokens.midnight.colors
        // The one non-colour token allowed to differ: a light palette takes the light
        // appearance (#176).
        tokens.windowAppearance = ThemeTokens.midnight.windowAppearance
        tokens.panels = ThemeTokens.Panels(
            popover: shape(tokens.panels.popover),
            quickPaste: shape(tokens.panels.quickPaste),
            toast: shape(tokens.panels.toast)
        )
        tokens.shadows = ThemeTokens.Shadows(
            window: shape(tokens.shadows.window),
            menu: shape(tokens.shadows.menu),
            alert: shape(tokens.shadows.alert),
            closeButton: shape(tokens.shadows.closeButton)
        )
        return tokens
    }

    private func shape(_ panel: PanelShell) -> PanelShell {
        var panel = panel
        if case let .fill(_, blur) = panel.background {
            panel.background = .fill(.hex(0), blur: blur)
        }
        panel.edge = panel.edge.map { _ in .hex(0) }
        panel.shadow = shape(panel.shadow)
        return panel
    }

    private func shape(_ shadow: ThemeShadow) -> ThemeShadow {
        guard case let .drop(_, blur, x, y) = shadow else { return shadow }
        return .drop(color: .hex(0), blur: blur, x: x, y: y)
    }

    func testTheThemesDifferOnlyInColours() {
        XCTAssertEqual(daylight.type, midnight.type, "type")
        XCTAssertEqual(daylight.radii, midnight.radii, "radii")
        XCTAssertEqual(daylight.sizes, midnight.sizes, "sizes")
        XCTAssertEqual(daylight.spacing, midnight.spacing, "spacing")
        XCTAssertEqual(shape(daylight).panels, shape(midnight).panels, "panels")
        XCTAssertEqual(shape(daylight).shadows, shape(midnight).shadows, "shadows")
        XCTAssertEqual(daylight.controlMetrics, midnight.controlMetrics, "controlMetrics")
        XCTAssertEqual(daylight.settingsWindow, midnight.settingsWindow, "settingsWindow")
        XCTAssertEqual(daylight.popover, midnight.popover, "popover")
        XCTAssertEqual(daylight.quickPasteMarker, midnight.quickPasteMarker, "quickPasteMarker")
        XCTAssertEqual(daylight.toast, midnight.toast, "toast")
        XCTAssertEqual(daylight.fullHistory, midnight.fullHistory, "fullHistory")
        XCTAssertEqual(daylight.historyReader, midnight.historyReader, "historyReader")
        XCTAssertEqual(daylight.resetUsage, midnight.resetUsage, "resetUsage")
        XCTAssertEqual(daylight.usageBreakdown, midnight.usageBreakdown, "usageBreakdown")
        XCTAssertEqual(daylight.welcome, midnight.welcome, "welcome")
        // Relaxed on purpose (#176): the appearance follows the palette.
        XCTAssertEqual(daylight.windowAppearance, .light, "windowAppearance")
        XCTAssertEqual(midnight.windowAppearance, .dark, "windowAppearance")
        // Everything at once, so a group added later is held too.
        XCTAssertTrue(shape(daylight) == shape(midnight), "the tokens differ outside the colours")
    }

    /// Each theme still resolves to its own value set and names its own theme.
    func testEachThemeKeepsItsIdentity() {
        XCTAssertEqual(daylight.theme, .daylight)
        XCTAssertEqual(midnight.theme, .midnight)
    }
}
