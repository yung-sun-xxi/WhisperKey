import AppKit
import QuickPaste
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

final class ThemeTokensTests: XCTestCase {
    func testEachThemeResolvesToItsOwnValueSet() {
        XCTAssertEqual(AppTheme.classic.tokens, ThemeTokens.classic)
        XCTAssertEqual(AppTheme.midnight.tokens, ThemeTokens.midnight)
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.tokens.theme, theme)
        }
    }

    /// Every group differs between the themes, so no group of Midnight was left a copy
    /// of Classic.
    func testTheThemesDifferInEveryGroup() {
        let classic = ThemeTokens.classic
        let midnight = ThemeTokens.midnight
        XCTAssertNotEqual(classic.colors, midnight.colors)
        XCTAssertNotEqual(classic.type, midnight.type)
        XCTAssertNotEqual(classic.radii, midnight.radii)
        XCTAssertNotEqual(classic.sizes, midnight.sizes)
        XCTAssertNotEqual(classic.spacing, midnight.spacing)
        XCTAssertNotEqual(classic.panels, midnight.panels)
        XCTAssertNotEqual(classic.shadows, midnight.shadows)
        XCTAssertNotEqual(classic.controls, midnight.controls)
        XCTAssertNotEqual(classic.windowChrome, midnight.windowChrome)
        XCTAssertNotEqual(classic.controlMetrics, midnight.controlMetrics)
        XCTAssertNotEqual(classic.settingsWindow, midnight.settingsWindow)
    }

    /// Classic is the look the views draw today. These are the values held in package
    /// code the views are built from; the rest are read from app views and named on
    /// `ThemeTokens.classic`.
    func testClassicMatchesTheQuickPasteLayout() {
        let classic = ThemeTokens.classic
        XCTAssertEqual(classic.sizes.listRow, QuickPasteLayout.rowHeight)
        XCTAssertEqual(classic.panels.quickPaste.width, QuickPasteLayout.contentWidth)
        XCTAssertEqual(classic.spacing.rowInset, QuickPasteLayout.horizontalPadding)
    }

    func testClassicIsTodaysLook() {
        let classic = ThemeTokens.classic
        // PopoverTypography
        XCTAssertEqual(classic.type.body, ThemeFont(size: 13, weight: .regular))
        XCTAssertEqual(classic.type.title, ThemeFont(size: 13, weight: .semibold))
        XCTAssertEqual(classic.type.small, ThemeFont(size: 12, weight: .regular))
        XCTAssertEqual(classic.colors.primaryText, .system(.label))
        XCTAssertEqual(classic.colors.secondaryText, .system(.secondaryLabel))
        // HeaderSurfaceColor
        XCTAssertEqual(classic.colors.card, .system(.primary, opacity: 0.075))
        XCTAssertEqual(classic.colors.divider, .system(.primary, opacity: 0.14))
        // SettingsWindowLayout
        XCTAssertEqual(classic.colors.settingsSurface, .system(.controlBackground))
        XCTAssertEqual(classic.sizes.control, 22)
        XCTAssertEqual(classic.spacing.windowTextEdge, 18)
        // MenuBarLayout.popoverWidth, MenuBarPanel.cornerRadius
        XCTAssertEqual(classic.panels.popover.width, 306)
        XCTAssertEqual(classic.panels.popover.radius, 12)
        XCTAssertEqual(classic.panels.popover.background, .material(.popover))
        // ToastView
        XCTAssertEqual(classic.panels.toast.width, 380)
        XCTAssertEqual(classic.panels.toast.radius, 14)
        XCTAssertEqual(classic.panels.toast.background, .material(.hudWindow))
        XCTAssertEqual(classic.panels.toast.shadow.swiftUIRadius, 8)
        // The accent colour, not a palette of ours.
        XCTAssertEqual(classic.colors.brand, .system(.accent))
        // Classic draws no shadow of its own on windows, menus or alerts.
        XCTAssertEqual(classic.shadows, ThemeTokens.Shadows(window: .system, menu: .system, alert: .system))
    }

    func testHexColoursAreSRGBInTheirByteOrder() throws {
        let color = try XCTUnwrap(NSColor(ThemeColor.hex(0xE24631, opacity: 0.5).color).usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0xE2 / 255, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0x46 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0x31 / 255, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 0.5, accuracy: 0.001)
    }

    func testCapsHeaderTrackingIsInPoints() {
        let font = ThemeFont(size: 11, weight: .medium, trackingEm: 0.06)
        XCTAssertEqual(font.tracking, 0.66, accuracy: 0.0001)
    }

    func testShadowRadiusIsHalfTheBlur() {
        XCTAssertEqual(ThemeShadow.drop(color: .hex(0), blur: 48, x: 0, y: 22).swiftUIRadius, 24)
        XCTAssertNil(ThemeShadow.system.swiftUIRadius)
    }

    func testAViewOutsideAThemedRootSeesClassic() {
        XCTAssertEqual(EnvironmentValues().themeTokens, ThemeTokens.classic)
    }
}
