import AppKit
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

final class ThemeTokensTests: XCTestCase {
    func testEachThemeResolvesToItsOwnValueSet() {
        XCTAssertEqual(AppTheme.daylight.tokens, ThemeTokens.daylight)
        XCTAssertEqual(AppTheme.midnight.tokens, ThemeTokens.midnight)
        for theme in AppTheme.allCases {
            XCTAssertEqual(theme.tokens.theme, theme)
        }
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

    func testAViewOutsideAThemedRootSeesDaylight() {
        XCTAssertEqual(EnvironmentValues().themeTokens, ThemeTokens.daylight)
    }
}
