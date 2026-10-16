import AppKit
import Combine
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The welcome window (#185): Settings' chrome over `surface`, a `divider` line under the
/// titlebar, then, padded 20 and centred, the 13/600 heading, 6 below it the 13 line in
/// `primaryText` at the body's line height, and 16 below that the two buttons 8 apart:
/// "Go to Settings", the default button in the active tab's red, then "Later", a push
/// button. Every value from the tokens, the same in both themes.
@MainActor
final class WelcomeThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Tokens

    /// `docs/design/dark/master-design.dc.html`, "6 · WELCOME · 390".
    func testTheMetricsAreTheDesigns() {
        let metrics = midnight.welcome
        // "width:390px".
        XCTAssertEqual(metrics.contentWidth, 390)
        // The body, "padding:20px".
        XCTAssertEqual(metrics.padding, 20)
        // The line, "margin-top:6px".
        XCTAssertEqual(metrics.headingGap, 6)
        // The buttons, "margin-top:16px;display:flex;gap:8px".
        XCTAssertEqual(metrics.buttonsGap, 16)
        XCTAssertEqual(metrics.buttonGap, 8)
    }

    /// The shared tokens the window borrows: the 13/600 heading, the 13 line at 1.45, the
    /// 13/500 default button label, the push button's 26 box padded 10 at radius 6.
    func testTheSharedTokensAreTheDesigns() {
        XCTAssertEqual(midnight.type.title, ThemeFont(size: 13, weight: .semibold))
        XCTAssertEqual(midnight.type.body, ThemeFont(size: 13, weight: .regular))
        XCTAssertEqual(midnight.type.bodyLineHeight, 1.45)
        XCTAssertEqual(midnight.type.defaultButton, ThemeFont(size: 13, weight: .medium))
        XCTAssertEqual(midnight.sizes.control, 26)
        XCTAssertEqual(midnight.controlMetrics.horizontalPadding, 10)
        XCTAssertEqual(midnight.radii.control, 6)
        XCTAssertEqual(midnight.controlMetrics.edgeWidth, 1)
        // "background:#E24631;border:1px solid #E24631", label "color:#14161A".
        XCTAssertEqual(midnight.colors.brand, .hex(0xE24631))
        XCTAssertEqual(midnight.colors.onBrand, .hex(0x14161A))
    }

    func testBothThemesShareEverySize() {
        XCTAssertEqual(ThemeTokens.daylight.welcome, midnight.welcome)
    }

    // MARK: - The drawn view

    func testTheViewIsTheContentWidth() {
        for theme in AppTheme.allCases {
            let host = hosted(theme: theme)
            XCTAssertEqual(host.fittingSize.width, midnight.welcome.contentWidth, "\(theme)")
        }
    }

    /// Top to bottom: the divider, 20, the heading's line, 6, the text's two lines at
    /// 1.45 × 13, 16, the 26 buttons, 20.
    func testTheHeightIsTheDesignsStack() {
        let metrics = midnight.welcome
        let type = midnight.type
        let heading = NSLayoutManager().defaultLineHeight(for: type.title.nsFont)
        let line = type.body.size * CGFloat(type.bodyLineHeight ?? 1)
        let top: CGFloat = midnight.controlMetrics.edgeWidth + metrics.padding + heading
        let middle: CGFloat = metrics.headingGap + 2 * line
        let bottom: CGFloat = metrics.buttonsGap + midnight.sizes.control + metrics.padding
        let expected = top + middle + bottom
        for theme in AppTheme.allCases {
            XCTAssertEqual(hosted(theme: theme).fittingSize.height, expected, accuracy: 1, "\(theme)")
        }
    }

    /// The default button is the push button's box in the brand: as tall, `brand` fill and
    /// edge, in each theme.
    func testTheDefaultButtonIsThePushButtonInTheBrand() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let source = ThemeTokensSource(theme: theme)
            let button = ThemedRoot("test", source: source) { ThemedDefaultButton("Go to Settings") {}.fixedSize() }
            let push = ThemedRoot("test", source: source) { ThemedPushButton("Go to Settings") {}.fixedSize() }
            let size = NSHostingView(rootView: button).fittingSize
            XCTAssertEqual(size.height, tokens.sizes.control, "\(theme)")
            XCTAssertEqual(size.height, NSHostingView(rootView: push).fittingSize.height, "\(theme)")

            let shot = try XCTUnwrap(Snapshot.render(button, size: size))
            // Inside the 10 padding, clear of the label: the edge, then the fill.
            for x in [CGFloat(0.5), 4] {
                let sample = shot.colour(x: x, screenY: size.height / 2, height: size.height)
                XCTAssertTrue(sample.matches(tokens.colors.brand), "\(theme) x \(x): \(sample)")
            }
        }
    }

    /// Body on `surface`, the line under the titlebar in `divider`, Go to Settings in
    /// `brand`, Later on `card`; the buttons centred as a group, the default first, 8
    /// apart.
    func testTheButtonsAreCentredInOrderWithTheGap() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let row = try buttonRow(theme: theme)
            XCTAssertTrue(row.top.matches(tokens.colors.divider), "\(theme) divider: \(row.top)")
            XCTAssertTrue(row.body.matches(tokens.colors.surface), "\(theme) body: \(row.body)")

            let brand = try XCTUnwrap(row.firstBrand, "\(theme): no brand on the button row")
            let brandEnd = try XCTUnwrap(row.lastBrand)
            let laterStart = try XCTUnwrap(row.firstAfterBrand, "\(theme): nothing after the default button")
            let end = try XCTUnwrap(row.lastDrawn)
            XCTAssertLessThan(brand, laterStart, "\(theme): Go to Settings is not first")
            XCTAssertEqual(laterStart - brandEnd, tokens.welcome.buttonGap, accuracy: 1, "\(theme) gap")
            XCTAssertEqual((brand + end) / 2, tokens.welcome.contentWidth / 2, accuracy: 1, "\(theme) not centred")
            XCTAssertTrue(row.laterFill.matches(tokens.colors.card), "\(theme) Later: \(row.laterFill)")
        }
    }

    /// A theme switch with the view open repaints it and moves nothing.
    func testAThemeSwitchRepaintsTheViewAndMovesNothing() throws {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        settle(host)
        let size = host.fittingSize
        let before = try buttonRow(of: host, size: size)

        for theme in [AppTheme.daylight, .midnight] {
            store.theme = theme
            settle(host)
            XCTAssertEqual(host.fittingSize, size, "\(theme)")
            let after = try buttonRow(of: host, size: size)
            XCTAssertTrue(after.body.matches(theme.tokens.colors.surface), "\(theme) body: \(after.body)")
            XCTAssertEqual(after.firstBrand, before.firstBrand, "\(theme)")
            XCTAssertEqual(after.lastBrand, before.lastBrand, "\(theme)")
            XCTAssertEqual(after.lastDrawn, before.lastDrawn, "\(theme)")
        }
    }

    // MARK: - The window

    /// The welcome window's chrome: content at the drawn view's fitting size, the
    /// titlebar see-through over `surface`, the theme's appearance; a theme switch with
    /// the window open repaints it and moves and resizes nothing.
    func testAThemeSwitchRepaintsTheWindowAndMovesNothing() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view })
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.contentView = host
        window.setContentSize(host.fittingSize)
        ThemedSurfaceWindow.configure(window, tokens: source.tokens)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.backgroundColor, midnight.colors.surface.nsColor)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentLayoutRect.width, midnight.welcome.contentWidth)

        let follower = ThemedSurfaceWindow.follow(source, window: window)
        defer { follower.cancel() }
        window.setFrameOrigin(NSPoint(x: 123, y: 234))
        let frame = window.frame

        for theme in [AppTheme.daylight, .midnight] {
            window.backgroundColor = .systemPink
            store.theme = theme
            settle(host)
            XCTAssertEqual(window.backgroundColor, theme.tokens.colors.surface.nsColor, "\(theme)")
            XCTAssertEqual(window.appearance?.name, theme.tokens.windowAppearance.nsAppearance?.name, "\(theme)")
            XCTAssertEqual(window.frame, frame, "\(theme)")
        }
    }

    // MARK: - Helpers

    private var view: some View {
        ThemedWelcomeView(goToSettings: {}, doLater: {})
    }

    private func hosted(theme: AppTheme) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { view })
        settle(host)
        return host
    }

    /// What the button row and its surroundings draw, read from a render.
    private struct ButtonRow {
        let top: Sample
        let body: Sample
        let laterFill: Sample
        let firstBrand: CGFloat?
        let lastBrand: CGFloat?
        let firstAfterBrand: CGFloat?
        let lastDrawn: CGFloat?
    }

    private func buttonRow(theme: AppTheme) throws -> ButtonRow {
        let root = ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { view }
        let size = NSHostingView(rootView: root).fittingSize
        let shot = try XCTUnwrap(Snapshot.render(root, size: size))
        return read(shot, size: size, tokens: theme.tokens)
    }

    private func buttonRow(of host: NSView, size: CGSize) throws -> ButtonRow {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let shot = Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width)
        return read(shot, size: size, tokens: midnight)
    }

    /// The row through the buttons' middle, 20 + 13 above the bottom; a pixel is the
    /// brand when nearer `brand` than `surface`, drawn when it is not `surface`.
    private func read(_ shot: Snapshot, size: CGSize, tokens: ThemeTokens) -> ButtonRow {
        let rowY = tokens.welcome.padding + tokens.sizes.control / 2
        let step = 1 / shot.scale
        // The theme may have switched since `tokens` was read: compare against both.
        let brands = AppTheme.allCases.map(\.tokens.colors.brand)
        let surfaces = AppTheme.allCases.map(\.tokens.colors.surface)
        var pixels: [(x: CGFloat, isBrand: Bool, isSurface: Bool)] = []
        var x: CGFloat = 0
        while x < size.width {
            let sample = shot.colour(x: x, screenY: rowY, height: size.height)
            pixels.append((x, brands.contains { sample.matches($0) }, surfaces.contains { sample.matches($0) }))
            x += step
        }
        // The default button runs from its first brand pixel to its last (its label in
        // between); Later starts at the first drawn pixel after it.
        let firstBrand = pixels.first(where: \.isBrand)?.x
        let lastBrand = pixels.last(where: \.isBrand).map { $0.x + step }
        let firstAfterBrand = lastBrand.flatMap { end in pixels.first { $0.x >= end && !$0.isSurface }?.x }
        let lastDrawn = pixels.last(where: { !$0.isSurface }).map { $0.x + step }
        let laterFillX = (firstAfterBrand ?? 0) + 4
        return ButtonRow(
            top: shot.colour(x: 4, screenY: size.height - step / 2, height: size.height),
            body: shot.colour(x: 4, screenY: size.height / 2, height: size.height),
            laterFill: shot.colour(x: laterFillX, screenY: rowY, height: size.height),
            firstBrand: firstBrand,
            lastBrand: lastBrand,
            firstAfterBrand: firstAfterBrand,
            lastDrawn: lastDrawn
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
