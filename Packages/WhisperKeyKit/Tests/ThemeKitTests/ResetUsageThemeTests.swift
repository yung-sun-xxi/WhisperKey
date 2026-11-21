import XCTest
@testable import ThemeKit

/// The Reset usage window's tokens (#183): the design's values, one set for both themes,
/// and the pure rules of its select-all box.
final class ResetUsageThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    func testTheMetricsAreTheDesigns() {
        let metrics = midnight.resetUsage
        XCTAssertEqual(metrics.contentWidth, 420)
        XCTAssertEqual(metrics.contentPaddingTop, 14)
        XCTAssertEqual(metrics.contentPaddingBottom, 16)
        XCTAssertEqual(metrics.cardGap, 14)
        XCTAssertEqual(metrics.cardInset, 4)
        XCTAssertEqual(metrics.rowGap, 10)
        XCTAssertEqual(metrics.pillPadding, 6)
        XCTAssertEqual(metrics.actionGap, 8)
        XCTAssertEqual(metrics.visibleRows, 6)
    }

    func testBothThemesShareEverySize() {
        XCTAssertEqual(ThemeTokens.daylight.resetUsage, midnight.resetUsage)
    }

    func testTheSelectAllBoxIsEmptyMixedOrFull() {
        XCTAssertEqual(ThemedResetUsageView.selectAllState(selected: 0, total: 4), .none)
        XCTAssertEqual(ThemedResetUsageView.selectAllState(selected: 2, total: 4), .some)
        XCTAssertEqual(ThemedResetUsageView.selectAllState(selected: 4, total: 4), .all)
        XCTAssertEqual(ThemedResetUsageView.selectAllState(selected: 0, total: 0), .none)
    }

    func testTheButtonOffersSelectAllUnlessEverythingIsTicked() {
        XCTAssertEqual(ThemedResetUsageView.selectAllTitle(selected: 3, total: 3), "Deselect all")
        XCTAssertEqual(ThemedResetUsageView.selectAllTitle(selected: 2, total: 3), "Select all")
    }
}
