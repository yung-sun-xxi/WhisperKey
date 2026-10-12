import XCTest
@testable import ThemeKit

/// The themes differ only in colours (decided 2026-10-11): one layout, one set of
/// controls, one window chrome. A second palette may change any colour and nothing else.
final class ThemeParityTests: XCTestCase {
    private let classic = ThemeTokens.classic
    private let midnight = ThemeTokens.midnight

    /// A theme's tokens with every colour set to one value, so only the shape is left.
    private func shape(_ tokens: ThemeTokens) -> ThemeTokens {
        var tokens = tokens
        tokens.theme = .midnight
        tokens.colors = ThemeTokens.midnight.colors
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
        XCTAssertEqual(classic.type, midnight.type, "type")
        XCTAssertEqual(classic.radii, midnight.radii, "radii")
        XCTAssertEqual(classic.sizes, midnight.sizes, "sizes")
        XCTAssertEqual(classic.spacing, midnight.spacing, "spacing")
        XCTAssertEqual(shape(classic).panels, shape(midnight).panels, "panels")
        XCTAssertEqual(shape(classic).shadows, shape(midnight).shadows, "shadows")
        XCTAssertEqual(classic.controlMetrics, midnight.controlMetrics, "controlMetrics")
        XCTAssertEqual(classic.settingsWindow, midnight.settingsWindow, "settingsWindow")
        XCTAssertEqual(classic.popover, midnight.popover, "popover")
        XCTAssertEqual(classic.quickPasteMarker, midnight.quickPasteMarker, "quickPasteMarker")
        XCTAssertEqual(classic.toast, midnight.toast, "toast")
        XCTAssertEqual(classic.windowAppearance, midnight.windowAppearance, "windowAppearance")
        // Everything at once, so a group added later is held too.
        XCTAssertTrue(shape(classic) == shape(midnight), "the tokens differ outside the colours")
    }

    /// Each theme still resolves to its own value set and names its own theme.
    func testEachThemeKeepsItsIdentity() {
        XCTAssertEqual(classic.theme, .classic)
        XCTAssertEqual(midnight.theme, .midnight)
    }
}
