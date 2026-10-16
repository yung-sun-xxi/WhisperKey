import AppKit
import Combine
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The full history window (#164): Settings' chrome, a count bar on 01 between two 03
/// dividers, and the popover's list rows on 02 with an absolute timestamp, every value
/// from the tokens, the same in both themes.
@MainActor
final class FullHistoryThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Tokens

    func testMidnightFullHistoryTokensAreTheDesign() {
        let history = midnight.fullHistory
        // The app's window, kept: 560 × 500, at least 420 × 320.
        XCTAssertEqual(history.contentSize, CGSize(width: 560, height: 500))
        XCTAssertEqual(history.minContentSize, CGSize(width: 420, height: 320))
        // "border-top:1px solid #23262D" above the count bar and above the list.
        XCTAssertEqual(history.dividerWidth, 1)
        // The count: "font-size:13px … tabular-nums", then "gap:6px" before the noun.
        XCTAssertEqual(history.count, ThemeFont(size: 13, weight: .regular, tabularDigits: true))
        XCTAssertEqual(history.countGap, 6)
        // The list area: "padding:8px 12px".
        XCTAssertEqual(history.listPaddingVertical, 8)
        XCTAssertEqual(history.listPaddingHorizontal, 12)
        // A row: "gap:10px"; a failed row "gap:8px", its timestamp "margin-left:2px".
        XCTAssertEqual(history.rowGap, 10)
        XCTAssertEqual(history.failedRowGap, 8)
        // The timestamp: "font-size:11px … tabular-nums".
        XCTAssertEqual(history.timestamp, ThemeFont(size: 11, weight: .regular, tabularDigits: true))
        // The empty list: "tray glyph 22 in 06, 4 above a 13/400 line in 07".
        XCTAssertEqual(history.emptyGlyph, ThemeFont(size: 22, weight: .regular))
        XCTAssertEqual(history.emptyGap, 4)
    }

    /// The count is the body and the timestamp the caption, both with tabular digits; the
    /// tray is the sheet's "+ empty-list glyph"; the bar is the sheet's action bar.
    func testTheFullHistoryTypeIsTheSheets() throws {
        let sheet = try TokenSheet.load()
        let history = midnight.fullHistory
        var body = midnight.type.body
        body.tabularDigits = true
        XCTAssertEqual(history.count, body)
        var caption = midnight.type.caption
        caption.tabularDigits = true
        XCTAssertEqual(history.timestamp, caption)
        XCTAssertEqual(history.emptyGlyph.size, try sheet.size("+ empty-list glyph"))
        XCTAssertTrue(try sheet.cell(firstColumn: "+ empty-list glyph", column: 2).contains("Full history"))
        XCTAssertEqual(midnight.sizes.actionBar, try sheet.size("+ action bar"))
        // "rows are the popover's rows": the gap between a row's parts is the popover's.
        XCTAssertEqual(history.rowGap, midnight.popover.rowGap)
    }

    func testBothThemesShareTheFullHistory() {
        XCTAssertEqual(ThemeTokens.daylight.fullHistory, midnight.fullHistory)
    }

    // MARK: - The count's words

    /// Today's text, drawn in two parts: "1 entry", "N entries".
    func testTheCountKeepsTodaysText() {
        for (count, label) in [(0, "0 entries"), (1, "1 entry"), (2, "2 entries"), (30, "30 entries"), (1000, "1000 entries")] {
            let parts = ThemedFullHistoryView.countParts(count)
            XCTAssertEqual("\(parts.number) \(parts.noun)", label)
        }
    }

    // MARK: - The count bar

    /// The bar is `actionBar` tall on 01, with a 03 divider above and below it; the list
    /// area under it is 02.
    func testTheCountBarIsTheActionBarBetweenTwoDividers() throws {
        let image = try render(rows: rows(3))
        let size = midnight.fullHistory.contentSize
        let top = size.height
        let line = midnight.fullHistory.dividerWidth
        let bar = midnight.sizes.actionBar
        // Between the noun and the button, where the bar holds nothing.
        let x = size.width / 2
        func at(_ y: CGFloat) -> Sample { image.colour(x: x, screenY: y, height: size.height) }

        XCTAssertTrue(at(top - 0.25).matches(midnight.colors.divider), "divider above: \(at(top - 0.25))")
        for y in [top - line - 0.25, top - line - bar / 2, top - line - bar + 0.25] {
            XCTAssertTrue(at(y).matches(midnight.colors.bar), "bar at \(y): \(at(y))")
        }
        XCTAssertTrue(at(top - line - bar - 0.25).matches(midnight.colors.divider), "divider below: \(at(top - line - bar - 0.25))")
        XCTAssertTrue(at(top - 2 * line - bar - 0.25).matches(midnight.colors.surface), "list area: \(at(top - 2 * line - bar - 0.25))")
    }

    /// The noun starts `countGap` after the number, which starts at the window text edge.
    func testTheCountIsTheNumberThenTheNounAtTheTextEdge() throws {
        let image = try render(rows: rows(3))
        let history = midnight.fullHistory
        let barTop = history.dividerWidth
        let band = CGRect(x: 0, y: barTop, width: history.contentSize.width / 2, height: midnight.sizes.actionBar)
        let ink = try XCTUnwrap(image.inkColumns(in: band, background: midnight.colors.bar))

        let number = try reference(Text("3").font(history.count.font), in: midnight.colors.primaryText)
        let noun = try reference(Text("entries").font(midnight.type.caption.font), in: midnight.colors.secondaryText)
        let numberLeft = midnight.spacing.windowTextEdge
        XCTAssertEqual(ink.first!, numberLeft + number.ink.minX, accuracy: 0.75, "the number's left")
        // The first ink after the number's own is the noun's.
        let nounLeft = numberLeft + number.size.width + history.countGap
        let nounInk = try XCTUnwrap(ink.first { $0 > numberLeft + number.ink.maxX + 1 })
        XCTAssertEqual(nounInk, nounLeft + noun.ink.minX, accuracy: 0.75, "the noun's left")
    }

    /// Clear history ends at the window text edge; with entries it is the push button's 03
    /// box, without them the sheet's disabled control, no fill on the bar.
    func testClearHistoryIsAPushButtonDisabledWhenEmpty() throws {
        let history = midnight.fullHistory
        let size = history.contentSize
        let barMid = size.height - history.dividerWidth - midnight.sizes.actionBar / 2
        // Inside the box, 2 in from its trailing edge.
        let x = size.width - midnight.spacing.windowTextEdge - 2
        // Mid-height: clear of the rounded corners, and the title is padded well away.
        let y = barMid

        let filled = try render(rows: rows(3)).colour(x: x, screenY: y, height: size.height)
        XCTAssertTrue(filled.matches(midnight.colors.card), "enabled: \(filled)")
        let empty = try render(rows: []).colour(x: x, screenY: y, height: size.height)
        XCTAssertTrue(empty.matches(midnight.colors.bar), "disabled: \(empty)")
        // And just outside the box's trailing edge, the bar.
        let outside = try render(rows: rows(3)).colour(x: size.width - midnight.spacing.windowTextEdge + 1, screenY: y, height: size.height)
        XCTAssertTrue(outside.matches(midnight.colors.bar), "past the edge: \(outside)")
    }

    // MARK: - The rows

    /// The first row's text starts inside the list padding and the row padding, centred in
    /// a list row that starts `listPaddingVertical` under the count bar's divider.
    func testTheFirstRowsTextSitsInsideTheListAndRowPadding() throws {
        let image = try render(rows: rows(3))
        let history = midnight.fullHistory
        let rowTop = history.dividerWidth * 2 + midnight.sizes.actionBar + history.listPaddingVertical
        let band = CGRect(x: 0, y: rowTop, width: history.contentSize.width / 2, height: midnight.sizes.listRow)
        let ink = try XCTUnwrap(image.inkBounds(in: band, background: midnight.colors.surface))

        let text = try reference(Text(Self.sampleText).font(midnight.type.body.font), in: midnight.colors.primaryText)
        let left = history.listPaddingHorizontal + midnight.spacing.rowPadding
        XCTAssertEqual(ink.minX, left + text.ink.minX, accuracy: 0.75, "the text's left")
        let textTop = rowTop + (midnight.sizes.listRow - text.size.height) / 2
        XCTAssertEqual(ink.minY, textTop + text.ink.minY, accuracy: 0.75, "the text's top")
    }

    /// The timestamp is the last thing in the row, ending at the row padding inside the
    /// list padding.
    func testTheTimestampEndsAtTheTrailingPadding() throws {
        let image = try render(rows: rows(3))
        let history = midnight.fullHistory
        let width = history.contentSize.width
        let rowTop = history.dividerWidth * 2 + midnight.sizes.actionBar + history.listPaddingVertical
        let band = CGRect(x: width / 2, y: rowTop, width: width / 2, height: midnight.sizes.listRow)
        let ink = try XCTUnwrap(image.inkBounds(in: band, background: midnight.colors.surface))

        let stamp = try reference(Text(Self.sampleTimestamp).font(history.timestamp.font), in: midnight.colors.secondaryText)
        let right = width - history.listPaddingHorizontal - midnight.spacing.rowPadding
        XCTAssertEqual(ink.maxX, right - (stamp.size.width - stamp.ink.maxX), accuracy: 0.75, "the timestamp's right")
        // The timestamp is drawn in the secondary text colour.
        XCTAssertTrue(image.brightest(in: band, background: midnight.colors.surface).isNearer(to: midnight.colors.secondaryText, than: midnight.colors.primaryText))
    }

    /// Rows follow each other a list row apart, with nothing between them: no divider,
    /// no gap, and no selection bar anywhere.
    func testRowsAreListRowsWithNothingBetweenThem() throws {
        let image = try render(rows: rows(3))
        let history = midnight.fullHistory
        let rowTop = history.dividerWidth * 2 + midnight.sizes.actionBar + history.listPaddingVertical
        let row = midnight.sizes.listRow
        let half = history.contentSize.width / 2
        let first = try XCTUnwrap(image.inkBounds(in: CGRect(x: 0, y: rowTop, width: half, height: row), background: midnight.colors.surface))
        let third = try XCTUnwrap(image.inkBounds(in: CGRect(x: 0, y: rowTop + 2 * row, width: half, height: row), background: midnight.colors.surface))
        XCTAssertEqual(third.minY - first.minY, 2 * row, accuracy: 0.5)

        // Left of the text, from the top of the list area to the bottom: only the surface.
        let listTop = history.dividerWidth * 2 + midnight.sizes.actionBar
        let x = history.listPaddingHorizontal + midnight.spacing.rowPadding / 2
        var y = listTop + 0.25
        while y < history.contentSize.height {
            let sample = image.colour(x: x, screenY: history.contentSize.height - y, height: history.contentSize.height)
            XCTAssertTrue(sample.matches(midnight.colors.surface), "at \(y) from the top: \(sample)")
            y += 0.5
        }
        XCTAssertFalse(image.containsSaturated(), "a coloured pixel: the selection bar or a tint")
    }

    /// The hatched row fills the row's band inside the list padding: a hatch stripe within
    /// one period of the padding on the leading side.
    func testAFailedRowIsHatchedInsideTheListPadding() throws {
        let failed = ThemedFullHistoryView.Row(id: UUID(), text: "No speech detected", timestamp: Self.sampleTimestamp, isRecognized: false, canRetry: true)
        let image = try render(rows: [failed] + rows(2))
        let history = midnight.fullHistory
        let height = history.contentSize.height
        let rowMid = history.dividerWidth * 2 + midnight.sizes.actionBar + history.listPaddingVertical + midnight.sizes.listRow / 2
        // Nothing left of the list padding is the row.
        for x in stride(from: 0.25, to: history.listPaddingHorizontal - 0.5, by: 0.5) {
            let sample = image.colour(x: x, screenY: height - rowMid, height: height)
            XCTAssertTrue(sample.matches(midnight.colors.surface), "at x \(x): \(sample)")
        }
        // The first lighter stripe starts within a hatch period of the padding. A stripe
        // (08-grey at 18% over the failure fill) lies well away from 02; the fill alone
        // does not.
        let period = midnight.controlMetrics.failureHatchPeriod * 2.squareRoot()
        let surface = midnight.colors.surface.nsColor.usingColorSpace(.sRGB)!
        func isStripe(_ sample: Sample) -> Bool {
            guard let c = sample.colour else { return false }
            return abs(c.redComponent - surface.redComponent) + abs(c.greenComponent - surface.greenComponent)
                + abs(c.blueComponent - surface.blueComponent) > 0.15
        }
        var x = history.listPaddingHorizontal
        var found: CGFloat?
        while x < history.listPaddingHorizontal + period + 1 {
            if isStripe(image.colour(x: x, screenY: height - rowMid, height: height)) {
                found = x
                break
            }
            x += 0.5
        }
        XCTAssertNotNil(found, "no hatch at the row's leading edge")
    }

    // MARK: - The empty list

    /// The tray in 06 and "No transcriptions yet" in 07 under it, centred both ways in
    /// the list area.
    func testTheEmptyListIsTheTrayOverOneLineCentred() throws {
        let image = try render(rows: [])
        let history = midnight.fullHistory
        let size = history.contentSize
        let listTop = history.dividerWidth * 2 + midnight.sizes.actionBar
        let area = CGRect(x: 0, y: listTop, width: size.width, height: size.height - listTop)
        let ink = try XCTUnwrap(image.inkBounds(in: area, background: midnight.colors.surface))

        let glyph = try reference(Image(systemName: "tray").font(history.emptyGlyph.font), in: midnight.colors.mutedEdge)
        let line = try reference(Text("No transcriptions yet").font(midnight.type.body.font), in: midnight.colors.secondaryText)
        let stack = glyph.size.height + history.emptyGap + line.size.height
        let stackTop = listTop + (area.height - stack) / 2
        XCTAssertEqual(ink.minY, stackTop + glyph.ink.minY, accuracy: 0.75, "the tray's top")
        XCTAssertEqual(ink.maxY, stackTop + glyph.size.height + history.emptyGap + line.ink.maxY, accuracy: 0.75, "the line's bottom")
        XCTAssertEqual(ink.midX, size.width / 2, accuracy: 1, "centred across")

        let glyphBand = CGRect(x: 0, y: stackTop, width: size.width, height: glyph.size.height)
        let lineBand = CGRect(x: 0, y: stackTop + glyph.size.height + history.emptyGap, width: size.width, height: line.size.height)
        XCTAssertTrue(image.brightest(in: glyphBand, background: midnight.colors.surface).isNearer(to: midnight.colors.mutedEdge, than: midnight.colors.secondaryText), "the tray is not 06")
        XCTAssertTrue(image.brightest(in: lineBand, background: midnight.colors.surface).isNearer(to: midnight.colors.secondaryText, than: midnight.colors.primaryText), "the line is not 07")
    }

    // MARK: - A theme switch

    /// The hosted view follows a switch at the same size.
    func testAThemeSwitchMovesNothingInTheView() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        for list in [rows(3), []] {
            let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view(list) })
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

    /// Settings' chrome: the system titlebar, see-through over the window's 02, the theme's
    /// appearance, and the tokens' content size and minimum.
    func testTheWindowTakesTheChromeAndSizeFromTheTokens() {
        let window = makeWindow()
        ThemedFullHistoryWindow.configure(window, tokens: midnight)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.backgroundColor, midnight.colors.surface.nsColor)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, midnight.fullHistory.contentSize)
        XCTAssertEqual(window.contentMinSize, midnight.fullHistory.minContentSize)
    }

    /// A theme switch with the window open gives it the theme's colours again and moves
    /// and resizes nothing.
    func testAThemeSwitchRepaintsTheWindowAndMovesNothing() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let window = makeWindow()
        ThemedFullHistoryWindow.configure(window, tokens: source.tokens)
        let follower = ThemedFullHistoryWindow.follow(source, window: window)
        defer { follower.cancel() }
        window.setFrameOrigin(NSPoint(x: 123, y: 234))
        let frame = window.frame

        for theme in [AppTheme.daylight, .midnight] {
            window.backgroundColor = .systemPink
            // The opposite of the theme's appearance, so the switch has to set it.
            window.appearance = NSAppearance(named: theme.tokens.windowAppearance == .dark ? .aqua : .darkAqua)
            store.theme = theme
            XCTAssertEqual(window.backgroundColor, theme.tokens.colors.surface.nsColor, "\(theme)")
            XCTAssertEqual(window.appearance?.name, theme.tokens.windowAppearance.nsAppearance?.name, "\(theme)")
            XCTAssertEqual(window.frame, frame, "\(theme)")
        }
    }

    // MARK: - Helpers

    private static let sampleText = "Hello"
    private static let sampleTimestamp = "18 Sep 12:37"

    private func rows(_ count: Int) -> [ThemedFullHistoryView.Row] {
        (0..<count).map { _ in
            ThemedFullHistoryView.Row(id: UUID(), text: Self.sampleText, timestamp: Self.sampleTimestamp, isRecognized: true, canRetry: false)
        }
    }

    private func view(_ rows: [ThemedFullHistoryView.Row]) -> ThemedFullHistoryView {
        ThemedFullHistoryView(rows: rows, copiedID: nil, onClear: {}, onCopy: { _ in }, onOpen: { _ in }, onRetry: { _ in })
    }

    private func render(rows: [ThemedFullHistoryView.Row]) throws -> Snapshot {
        try XCTUnwrap(Snapshot.render(
            ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view(rows) },
            size: midnight.fullHistory.contentSize
        ))
    }

    /// A view drawn alone in `colour` on 02 at its own size: its size and where its ink
    /// lies in it, in points from its top-left corner.
    private func reference(_ content: some View, in colour: ThemeColor) throws -> (size: CGSize, ink: CGRect) {
        // Measured in a window like the one the view under test draws in, so on a 2x screen
        // both lay out in half points; drawn on a whole-point canvas from its top-left corner.
        let size = Snapshot.fittingSize(content.fixedSize())
        let canvas = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        let drawn = content.foregroundStyle(colour.color).fixedSize()
            .frame(width: size.width, height: size.height)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(midnight.colors.surface.color)
        let image = try XCTUnwrap(Snapshot.render(drawn, size: canvas))
        let ink = try XCTUnwrap(image.inkBounds(in: CGRect(origin: .zero, size: canvas), background: midnight.colors.surface))
        return (size, ink)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
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

/// Reading a rendered view by rectangles in points from its top-left corner.
private extension Snapshot {
    var pointSize: CGSize { CGSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale) }

    func pixel(_ px: Int, _ py: Int) -> NSColor? {
        rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
    }

    /// The pixels in `rect` and their colours.
    func pixels(in rect: CGRect) -> [(x: CGFloat, y: CGFloat, colour: NSColor)] {
        let minX = max(Int((rect.minX * scale).rounded(.down)), 0)
        let maxX = min(Int((rect.maxX * scale).rounded(.up)), rep.pixelsWide)
        let minY = max(Int((rect.minY * scale).rounded(.down)), 0)
        let maxY = min(Int((rect.maxY * scale).rounded(.up)), rep.pixelsHigh)
        var result: [(x: CGFloat, y: CGFloat, colour: NSColor)] = []
        guard minX < maxX, minY < maxY else { return result }
        for py in minY..<maxY {
            for px in minX..<maxX {
                if let colour = pixel(px, py) {
                    result.append((CGFloat(px) / scale, CGFloat(py) / scale, colour))
                }
            }
        }
        return result
    }

    /// Ink: a pixel clearly away from `background`.
    @MainActor
    func isInk(_ colour: NSColor, background: ThemeColor) -> Bool {
        guard let base = background.nsColor.usingColorSpace(.sRGB) else { return false }
        let distance = abs(colour.redComponent - base.redComponent)
            + abs(colour.greenComponent - base.greenComponent)
            + abs(colour.blueComponent - base.blueComponent)
        return distance > 0.25
    }

    /// The bounds of the ink in `rect`, in points from the top-left corner.
    @MainActor
    func inkBounds(in rect: CGRect, background: ThemeColor) -> CGRect? {
        let ink = pixels(in: rect).filter { isInk($0.colour, background: background) }
        guard let minX = ink.map(\.x).min(), let maxX = ink.map(\.x).max(),
              let minY = ink.map(\.y).min(), let maxY = ink.map(\.y).max() else { return nil }
        let pixel = 1 / scale
        return CGRect(x: minX, y: minY, width: maxX + pixel - minX, height: maxY + pixel - minY)
    }

    /// The left edge of every column holding ink in `rect`, left to right.
    @MainActor
    func inkColumns(in rect: CGRect, background: ThemeColor) -> [CGFloat]? {
        let columns = Set(pixels(in: rect).filter { isInk($0.colour, background: background) }.map(\.x)).sorted()
        return columns.isEmpty ? nil : columns
    }

    /// The pixel in `rect` farthest from `background`.
    @MainActor
    func brightest(in rect: CGRect, background: ThemeColor) -> Sample {
        let base = background.nsColor.usingColorSpace(.sRGB)!
        let best = pixels(in: rect).max { a, b in
            func distance(_ c: NSColor) -> CGFloat {
                abs(c.redComponent - base.redComponent) + abs(c.greenComponent - base.greenComponent) + abs(c.blueComponent - base.blueComponent)
            }
            return distance(a.colour) < distance(b.colour)
        }
        return Sample(colour: best?.colour)
    }

    /// Whether any pixel is a colour rather than a grey.
    func containsSaturated() -> Bool {
        pixels(in: CGRect(origin: .zero, size: pointSize)).contains { pixel in
            let c = pixel.colour
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            return c.alphaComponent > 0.5 && (channels.max()! - channels.min()!) > 0.15
        }
    }
}
