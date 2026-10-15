import AppKit
import Combine
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The Usage by model window (#184): Settings' chrome, the popover's period picker on a
/// `bar` band under a `divider` line, then a `card` holding the caps header, one 34 row
/// per model with `edge` hairlines between them, and the Total row under a full-width
/// `edge` line. Every value from the tokens, the same in both themes.
@MainActor
final class UsageBreakdownThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Tokens

    /// `docs/design/dark/master-design.dc.html`, "8a · USAGE BY MODEL · 540".
    func testTheMetricsAreTheDesigns() {
        let metrics = midnight.usageBreakdown
        // "width:540px", every period.
        XCTAssertEqual(metrics.contentWidth, 540)
        // The picker band: "padding:14px 20px;background:#14161A;border-top:1px".
        XCTAssertEqual(metrics.barPaddingVertical, 14)
        XCTAssertEqual(midnight.spacing.windowTextEdge, 20)
        // The content: "border-top:1px solid #23262D;padding:14px 20px 20px".
        XCTAssertEqual(metrics.contentPaddingTop, 14)
        XCTAssertEqual(metrics.contentPaddingBottom, 20)
        // The card: "padding:0 4px 4px".
        XCTAssertEqual(metrics.cardInset, 4)
        // The grid: "grid-template-columns:minmax(0,1fr) 56px 64px 48px;gap:12px".
        XCTAssertEqual(metrics.wordsColumn, 56)
        XCTAssertEqual(metrics.audioColumn, 64)
        XCTAssertEqual(metrics.costColumn, 48)
        XCTAssertEqual(metrics.columnGap, 12)
        // The empty card: "padding:40px 16px".
        XCTAssertEqual(metrics.emptyPaddingVertical, 40)
        XCTAssertEqual(metrics.emptyPaddingHorizontal, 16)
    }

    /// The shared tokens the window borrows: the 34 row padded 8, the 1px edge, the caps
    /// header, the 13 body and the 13/600 Total, the 8 card radius.
    func testTheSharedTokensAreTheDesigns() {
        XCTAssertEqual(midnight.sizes.listRow, 34)
        XCTAssertEqual(midnight.spacing.rowPadding, 8)
        XCTAssertEqual(midnight.controlMetrics.edgeWidth, 1)
        XCTAssertEqual(midnight.radii.card, 8)
        // "font-size:11px;font-weight:500;letter-spacing:0.06em".
        XCTAssertEqual(midnight.type.capsHeader, ThemeFont(size: 11, weight: .medium, trackingEm: 0.06))
        // "font-size:13px".
        XCTAssertEqual(midnight.type.body, ThemeFont(size: 13, weight: .regular))
        // "font-size:13px;font-weight:600".
        XCTAssertEqual(midnight.type.title, ThemeFont(size: 13, weight: .semibold))
    }

    func testBothThemesShareEverySize() {
        XCTAssertEqual(ThemeTokens.daylight.usageBreakdown, midnight.usageBreakdown)
    }

    // MARK: - The drawn view

    /// 540 wide for every period, with rows and without.
    func testTheViewIsTheContentWidthForEveryPeriod() {
        for rows in [lines(3), lines(1), []] {
            let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view(rows) })
            settle(host)
            XCTAssertEqual(host.fittingSize.width, midnight.usageBreakdown.contentWidth, "\(rows.count) rows")
        }
    }

    /// Top to bottom: a divider, the band (the picker's track padded 14), a divider, 14,
    /// the card (header row and its line, the rows with hairlines between them, the
    /// full-width line, Total, 4 below), 20.
    func testTheHeightIsTheDesignsStack() {
        let metrics = midnight.usageBreakdown
        let edge = midnight.controlMetrics.edgeWidth
        let row = midnight.sizes.listRow
        for count in [1, 3] {
            let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view(lines(count)) })
            settle(host)
            let band = metrics.barPaddingVertical * 2 + midnight.sizes.periodTrack
            let card = row + edge                                         // header and its line
                + CGFloat(count) * row + CGFloat(count - 1) * edge        // rows and hairlines
                + edge + row                                              // the Total line and row
                + metrics.cardInset
            let expected = edge + band + edge + metrics.contentPaddingTop + card + metrics.contentPaddingBottom
            XCTAssertEqual(host.fittingSize.height, expected, accuracy: 0.5, "\(count) rows")
        }
    }

    /// The empty period: the band, then the card alone, padded 40 around one body line.
    func testTheEmptyPeriodIsTheCardAlone() {
        let metrics = midnight.usageBreakdown
        let edge = midnight.controlMetrics.edgeWidth
        let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view([]) })
        settle(host)
        let band = metrics.barPaddingVertical * 2 + midnight.sizes.periodTrack
        let chrome = edge + band + edge + metrics.contentPaddingTop + metrics.contentPaddingBottom
        let card = host.fittingSize.height - chrome
        // One 13pt line is about 16 tall; the card is that plus 40 above and below.
        XCTAssertGreaterThan(card, metrics.emptyPaddingVertical * 2 + 12)
        XCTAssertLessThan(card, metrics.emptyPaddingVertical * 2 + 20)
    }

    /// A theme switch with the view open moves nothing.
    func testAThemeSwitchMovesNothingInTheView() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        for rows in [lines(3), []] {
            let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view(rows) })
            settle(host)
            let before = host.fittingSize
            store.theme = .daylight
            settle(host)
            XCTAssertEqual(host.fittingSize, before)
            store.theme = .midnight
            settle(host)
            XCTAssertEqual(host.fittingSize, before)
        }
    }

    // MARK: - The window

    /// Settings' chrome: the system titlebar, see-through over the window's 02, and the
    /// theme's appearance.
    func testTheWindowTakesTheSurfaceChrome() {
        let window = makeWindow()
        ThemedSurfaceWindow.configure(window, tokens: midnight)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.backgroundColor, midnight.colors.surface.nsColor)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }

    /// A theme switch with the window open repaints it and moves and resizes nothing.
    func testAThemeSwitchRepaintsTheWindowAndMovesNothing() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let window = makeWindow()
        ThemedSurfaceWindow.configure(window, tokens: source.tokens)
        let follower = ThemedSurfaceWindow.follow(source, window: window)
        defer { follower.cancel() }
        window.setFrameOrigin(NSPoint(x: 123, y: 234))
        let frame = window.frame

        for theme in [AppTheme.daylight, .midnight] {
            window.backgroundColor = .systemPink
            window.appearance = NSAppearance(named: theme.tokens.windowAppearance == .dark ? .aqua : .darkAqua)
            store.theme = theme
            XCTAssertEqual(window.backgroundColor, theme.tokens.colors.surface.nsColor, "\(theme)")
            XCTAssertEqual(window.appearance?.name, theme.tokens.windowAppearance.nsAppearance?.name, "\(theme)")
            XCTAssertEqual(window.frame, frame, "\(theme)")
        }
    }

    // MARK: - Helpers

    private enum Period: String, CaseIterable, Hashable {
        case today = "Today"
        case all = "All"
    }

    private func lines(_ count: Int) -> [UsageBreakdownLine] {
        (0..<count).map { index in
            UsageBreakdownLine(
                id: "model-\(index)",
                title: "OpenAI · gpt-4o-mini-transcribe-\(index)",
                figures: UsageBreakdownFigures(words: "41k", audio: "9h 02m", cost: "~$1.6")
            )
        }
    }

    private func view(_ rows: [UsageBreakdownLine]) -> some View {
        ThemedUsageBreakdownView(
            rows: rows,
            total: UsageBreakdownFigures(words: "90k", audio: "17h 18m", cost: "~$3.1")
        ) {
            ThemedPeriodPicker(
                "Period",
                selection: .constant(Period.all),
                options: Period.allCases,
                title: { $0.rawValue },
                help: { $0.rawValue }
            )
        }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
    }

    private func followedSource() -> (SettingsStore, ThemeTokensSource, () -> Void) {
        let suite = "WhisperKey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.theme = .midnight
        let source = ThemeTokensSource()
        source.follow(store)
        return (store, source, { defaults.removePersistentDomain(forName: suite) })
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }
}
