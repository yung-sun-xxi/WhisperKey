import AppKit
import Combine
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The history entry reader (#165): Settings' chrome, a 03 divider under the titlebar,
/// the date line with its language tag, the text in a 03 card, and an action bar on 01
/// under a 03 divider holding today's buttons, every value from the tokens, the same in
/// both themes.
@MainActor
final class HistoryReaderThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Tokens

    func testMidnightHistoryReaderTokensAreTheDesign() {
        let reader = midnight.historyReader
        // The app's window, kept: 480 × 280, at least 360 × 220.
        XCTAssertEqual(reader.contentSize, CGSize(width: 480, height: 280))
        XCTAssertEqual(reader.minContentSize, CGSize(width: 360, height: 220))
        // "border-top:1px solid #23262D" under the titlebar and above the action bar.
        XCTAssertEqual(reader.dividerWidth, 1)
        // The content: "gap:8px;padding:14px 20px".
        XCTAssertEqual(reader.contentPaddingVertical, 14)
        XCTAssertEqual(midnight.spacing.windowTextEdge, 20)
        XCTAssertEqual(reader.contentGap, 8)
        // The date: "font-size:11px;color:#9BA1AF;font-variant-numeric:tabular-nums".
        XCTAssertEqual(reader.date, ThemeFont(size: 11, weight: .regular, tabularDigits: true))
        // The language tag after it: the ticket's, a spacing step.
        XCTAssertEqual(reader.languageGap, 6)
        // The card: "background:#23262D;border-radius:8px;padding:10px 14px".
        XCTAssertEqual(reader.cardPaddingVertical, 10)
        XCTAssertEqual(reader.cardPaddingHorizontal, 14)
        XCTAssertEqual(midnight.radii.card, 8)
        // The action bar: "height:48px … gap:8px;padding:0 20px".
        XCTAssertEqual(midnight.sizes.actionBar, 48)
        XCTAssertEqual(reader.actionGap, 8)
    }

    /// The date and the tag are the sheet's 11/400, the date with tabular digits; the text
    /// is the body at the body line height; every gap is a spacing step.
    func testTheHistoryReaderTypeAndSpacingAreTheSheets() throws {
        let sheet = try TokenSheet.load()
        let reader = midnight.historyReader
        var caption = midnight.type.caption
        caption.tabularDigits = true
        XCTAssertEqual(reader.date, caption)
        XCTAssertEqual(midnight.type.body, ThemeFont(size: 13, weight: .regular))
        XCTAssertEqual(midnight.type.bodyLineHeight ?? 0, try sheet.number(after: "Body line-height"), accuracy: 0.0001)
        XCTAssertEqual(midnight.sizes.actionBar, try sheet.size("+ action bar"))
        let steps = try sheet.spacingSteps()
        for (name, value) in [
            ("contentPaddingVertical", reader.contentPaddingVertical),
            ("contentGap", reader.contentGap),
            ("languageGap", reader.languageGap),
            ("cardPaddingVertical", reader.cardPaddingVertical),
            ("cardPaddingHorizontal", reader.cardPaddingHorizontal),
            ("actionGap", reader.actionGap),
        ] {
            XCTAssertTrue(steps.contains(value), "\(name) \(value) is not a spacing step")
        }
    }

    func testBothThemesShareTheHistoryReader() {
        XCTAssertEqual(ThemeTokens.daylight.historyReader, midnight.historyReader)
    }

    // MARK: - Words and timing

    /// The language in caps, and no tag at all without one, as today.
    func testTheLanguageTagIsTheCodeInCaps() {
        XCTAssertEqual(ThemedHistoryReaderView.languageTag("en"), "EN")
        XCTAssertEqual(ThemedHistoryReaderView.languageTag("ru"), "RU")
        XCTAssertEqual(ThemedHistoryReaderView.languageTag("EN"), "EN")
        XCTAssertNil(ThemedHistoryReaderView.languageTag(nil))
        XCTAssertNil(ThemedHistoryReaderView.languageTag(""))
    }

    /// "Copy", reading "Copied" for today's 1.4 s after a click.
    func testCopyReadsCopiedForTodaysTime() {
        XCTAssertEqual(ThemedHistoryReaderView.copyTitle(copied: false), "Copy")
        XCTAssertEqual(ThemedHistoryReaderView.copyTitle(copied: true), "Copied")
        XCTAssertEqual(ThemedHistoryReaderView.copiedNanoseconds, 1_400_000_000)
    }

    // MARK: - The divider and the date line

    /// A 03 line under the titlebar, then the content on 02.
    func testADividerRunsUnderTheTitlebar() throws {
        let image = try render(reader())
        let size = midnight.historyReader.contentSize
        let line = midnight.historyReader.dividerWidth
        // Right of the date line, where the content holds nothing.
        let x = size.width - midnight.spacing.windowTextEdge / 2
        func at(_ y: CGFloat) -> Sample { image.colour(x: x, screenY: size.height - y, height: size.height) }
        XCTAssertTrue(at(0.25).matches(midnight.colors.divider), "divider: \(at(0.25))")
        XCTAssertTrue(at(line + 0.25).matches(midnight.colors.surface), "under it: \(at(line + 0.25))")
    }

    /// The date starts at the window text edge, `contentPaddingVertical` under the
    /// divider, in 07; the tag starts `languageGap` after it, in 07 too.
    func testTheDateLineIsTheDateThenTheTag() throws {
        let image = try render(reader())
        let reader = midnight.historyReader
        let date = try reference(Text(Self.sampleDate).font(reader.date.font), in: midnight.colors.secondaryText)
        let tag = try reference(Text("EN").font(midnight.type.caption.font), in: midnight.colors.secondaryText)
        let top = reader.dividerWidth + reader.contentPaddingVertical
        let band = CGRect(x: 0, y: top, width: reader.contentSize.width, height: date.size.height)
        let ink = try XCTUnwrap(image.inkBounds(in: band, background: midnight.colors.surface))
        let columns = try XCTUnwrap(image.inkColumns(in: band, background: midnight.colors.surface))

        let left = midnight.spacing.windowTextEdge
        XCTAssertEqual(ink.minX, left + date.ink.minX, accuracy: 0.75, "the date's left")
        XCTAssertEqual(ink.minY, top + date.ink.minY, accuracy: 0.75, "the date's top")
        let tagLeft = left + date.size.width + reader.languageGap
        let tagInk = try XCTUnwrap(columns.first { $0 > left + date.ink.maxX + 1 }, "no tag")
        XCTAssertEqual(tagInk, tagLeft + tag.ink.minX, accuracy: 0.75, "the tag's left")
        XCTAssertEqual(ink.maxX, tagLeft + tag.ink.maxX, accuracy: 0.75, "the tag's right: it sits after the date, not at the edge")
        XCTAssertTrue(image.brightest(in: band, background: midnight.colors.surface).isNearer(to: midnight.colors.secondaryText, than: midnight.colors.primaryText), "the date line is not 07")
    }

    /// Without a language, the date line is the date alone.
    func testNoLanguageNoTag() throws {
        let image = try render(reader(language: nil))
        let reader = midnight.historyReader
        let date = try reference(Text(Self.sampleDate).font(reader.date.font), in: midnight.colors.secondaryText)
        let top = reader.dividerWidth + reader.contentPaddingVertical
        let band = CGRect(x: 0, y: top, width: reader.contentSize.width, height: date.size.height)
        let ink = try XCTUnwrap(image.inkBounds(in: band, background: midnight.colors.surface))
        XCTAssertEqual(ink.maxX, midnight.spacing.windowTextEdge + date.ink.maxX, accuracy: 0.75)
    }

    // MARK: - The card

    /// The card is 03 from the text edge to the text edge, `contentGap` under the date
    /// line and `contentPaddingVertical` above the action bar's divider, with round
    /// corners.
    func testTheTextSitsInACardBetweenTheDateAndTheActionBar() throws {
        let image = try render(reader())
        let geometry = try cardGeometry()
        let height = midnight.historyReader.contentSize.height
        func at(_ x: CGFloat, _ y: CGFloat) -> Sample { image.colour(x: x, screenY: height - y, height: height) }
        let midY = (geometry.top + geometry.bottom) / 2
        let edge = midnight.spacing.windowTextEdge
        let width = midnight.historyReader.contentSize.width

        XCTAssertTrue(at(edge + 0.25, midY).matches(midnight.colors.card), "card's left: \(at(edge + 0.25, midY))")
        XCTAssertTrue(at(edge - 0.25, midY).matches(midnight.colors.surface), "left of it: \(at(edge - 0.25, midY))")
        XCTAssertTrue(at(width - edge - 0.25, midY).matches(midnight.colors.card), "card's right: \(at(width - edge - 0.25, midY))")
        XCTAssertTrue(at(width - edge + 0.25, midY).matches(midnight.colors.surface), "right of it: \(at(width - edge + 0.25, midY))")
        let x = width - edge - midnight.radii.card - 2
        XCTAssertTrue(at(x, geometry.top + 0.25).matches(midnight.colors.card), "card's top: \(at(x, geometry.top + 0.25))")
        XCTAssertTrue(at(x, geometry.top - 0.25).matches(midnight.colors.surface), "above it: \(at(x, geometry.top - 0.25))")
        XCTAssertTrue(at(x, geometry.bottom - 0.25).matches(midnight.colors.card), "card's bottom: \(at(x, geometry.bottom - 0.25))")
        XCTAssertTrue(at(x, geometry.bottom + 0.25).matches(midnight.colors.surface), "under it: \(at(x, geometry.bottom + 0.25))")
        // Round, not square, at the corner.
        XCTAssertTrue(at(edge + 0.25, geometry.top + 0.25).matches(midnight.colors.surface), "a square corner: \(at(edge + 0.25, geometry.top + 0.25))")
        // Round at `radii.card`. The render is one pixel a point, so take the pixel row 2-3
        // under the card's top: there the arc of radius r runs from r - √(r² - (r - 2)²)
        // to r - √(r² - (r - 3)²) in from the side. The whole pixel left of its middle is
        // the surface and the whole pixel right of its start the card; a radius 2 smaller
        // fills the first, one 2 larger leaves the second half empty.
        let r = midnight.radii.card
        func arc(_ dy: CGFloat) -> CGFloat { r - (r * r - (r - dy) * (r - dy)).squareRoot() }
        let y = geometry.top + 2.5
        let outside = (arc(2.5)).rounded(.down) - 0.5
        let inside = (arc(2)).rounded(.up) + 0.5
        XCTAssertTrue(at(edge + outside, y).matches(midnight.colors.surface), "the corner is tighter than radii.card: \(at(edge + outside, y))")
        XCTAssertTrue(at(edge + inside, y).matches(midnight.colors.card), "the corner is wider than radii.card: \(at(edge + inside, y))")
    }

    /// The text starts inside the card's padding, half the body's extra line height lower
    /// (CSS line height), in 08 for a recognised entry.
    func testTheTextIsTheBodyInsideTheCardPadding() throws {
        let image = try render(reader())
        let geometry = try cardGeometry()
        let reader = midnight.historyReader
        let edge = midnight.spacing.windowTextEdge
        let band = CGRect(x: edge, y: geometry.top, width: reader.contentSize.width - 2 * edge, height: geometry.bottom - geometry.top)
        let ink = try XCTUnwrap(image.inkBounds(in: band, background: midnight.colors.card))
        let text = try reference(Text(Self.sampleText).font(midnight.type.body.font), in: midnight.colors.primaryText)
        let extra = midnight.type.body.extraLineSpacing(lineHeight: try XCTUnwrap(midnight.type.bodyLineHeight))
        XCTAssertGreaterThan(extra, 0, "1.45 adds room to the 13pt line")

        XCTAssertEqual(ink.minX, edge + reader.cardPaddingHorizontal + text.ink.minX, accuracy: 0.75, "the text's left")
        XCTAssertEqual(ink.minY, geometry.top + reader.cardPaddingVertical + extra / 2 + text.ink.minY, accuracy: 0.75, "the text's top")
        XCTAssertTrue(image.brightest(in: band, background: midnight.colors.card).isNearer(to: midnight.colors.primaryText, than: midnight.colors.secondaryText), "a recognised text is not 08")
    }

    /// Lines of a long text are the body line height apart.
    func testLinesAreTheBodyLineHeightApart() throws {
        let long = Array(repeating: Self.sampleText, count: 60).joined(separator: " ")
        let image = try render(reader(text: long))
        let geometry = try cardGeometry()
        let reader = midnight.historyReader
        let edge = midnight.spacing.windowTextEdge
        let lineHeight = midnight.type.body.size * CGFloat(try XCTUnwrap(midnight.type.bodyLineHeight))
        // The first ink row of the first and the second line: each line's capital H.
        let x0 = edge + reader.cardPaddingHorizontal
        let column = CGRect(x: x0, y: geometry.top, width: 3, height: geometry.bottom - geometry.top)
        let rows = try XCTUnwrap(image.inkRows(in: column, background: midnight.colors.card))
        let firstTop = rows[0]
        let secondTop = try XCTUnwrap(rows.first { $0 > firstTop + midnight.type.body.size })
        XCTAssertEqual(secondTop - firstTop, lineHeight, accuracy: 0.75)
    }

    /// A failed entry's wording is 07.
    func testAFailedEntrysTextIsSecondary() throws {
        let image = try render(reader(text: "No speech detected", isRecognized: false, canRetry: true))
        let geometry = try cardGeometry()
        let edge = midnight.spacing.windowTextEdge
        let band = CGRect(x: edge, y: geometry.top, width: midnight.historyReader.contentSize.width - 2 * edge, height: geometry.bottom - geometry.top)
        XCTAssertTrue(image.brightest(in: band, background: midnight.colors.card).isNearer(to: midnight.colors.secondaryText, than: midnight.colors.primaryText), "a failed entry's text is not 07")
    }

    // MARK: - The action bar

    /// The bar is `actionBar` tall on 01 at the bottom, under a 03 divider.
    func testTheActionBarIsAtTheBottomUnderADivider() throws {
        let image = try render(reader())
        let reader = midnight.historyReader
        let height = reader.contentSize.height
        let bar = midnight.sizes.actionBar
        let x = reader.contentSize.width / 2
        func at(_ y: CGFloat) -> Sample { image.colour(x: x, screenY: height - y, height: height) }
        for y in [height - 0.25, height - bar / 2, height - bar + 0.25] {
            XCTAssertTrue(at(y).matches(midnight.colors.bar), "bar at \(y): \(at(y))")
        }
        let line = height - bar - reader.dividerWidth / 2
        XCTAssertTrue(at(line).matches(midnight.colors.divider), "divider: \(at(line))")
        XCTAssertTrue(at(height - bar - reader.dividerWidth - 0.25).matches(midnight.colors.surface), "above it: \(at(height - bar - reader.dividerWidth - 0.25))")
    }

    /// Copy starts at the window text edge and Close ends at it, both the push button's
    /// 03 box.
    func testCopyAndCloseSitAtTheTextEdges() throws {
        let image = try render(reader())
        let reader = midnight.historyReader
        let size = reader.contentSize
        let barMid = midnight.sizes.actionBar / 2
        let edge = midnight.spacing.windowTextEdge
        func at(_ x: CGFloat) -> Sample { image.colour(x: x, screenY: barMid, height: size.height) }
        XCTAssertTrue(at(edge + 2).matches(midnight.colors.card), "Copy's box: \(at(edge + 2))")
        XCTAssertTrue(at(edge - 1).matches(midnight.colors.bar), "before Copy: \(at(edge - 1))")
        XCTAssertTrue(at(size.width - edge - 2).matches(midnight.colors.card), "Close's box: \(at(size.width - edge - 2))")
        XCTAssertTrue(at(size.width - edge + 1).matches(midnight.colors.bar), "past Close: \(at(size.width - edge + 1))")
    }

    /// A failed entry has no Copy: Retry takes the leading place.
    func testAFailedEntryHasRetryInCopysPlace() throws {
        let image = try render(reader(text: "No speech detected", isRecognized: false, canRetry: true))
        let size = midnight.historyReader.contentSize
        let edge = midnight.spacing.windowTextEdge
        let retry = try buttonWidth("Retry")
        let copy = try buttonWidth("Copy")
        XCTAssertNotEqual(retry, copy, "the two buttons must differ in width for this test")
        let barMid = midnight.sizes.actionBar / 2
        func at(_ x: CGFloat) -> Sample { image.colour(x: x, screenY: barMid, height: size.height) }
        // 2 inside the trailing edge: clear of the 05 outline.
        XCTAssertTrue(at(edge + retry - 2).matches(midnight.colors.card), "Retry's box: \(at(edge + retry - 2))")
        XCTAssertTrue(at(edge + retry + 1).matches(midnight.colors.bar), "past Retry: \(at(edge + retry + 1))")

        // Neither Copy nor Retry on an entry that is neither recognised nor retryable.
        let bare = try render(reader(text: "Audio capture failed", isRecognized: false, canRetry: false))
        XCTAssertTrue(bare.colour(x: edge + 2, screenY: barMid, height: size.height).matches(midnight.colors.bar), "a button where there should be none")
    }

    /// Two leading buttons stand `actionGap` apart.
    func testTheButtonsAreTheActionGapApart() throws {
        let image = try render(reader(isRecognized: true, canRetry: true))
        let size = midnight.historyReader.contentSize
        let edge = midnight.spacing.windowTextEdge
        let copy = try buttonWidth("Copy")
        let gap = midnight.historyReader.actionGap
        let barMid = midnight.sizes.actionBar / 2
        func at(_ x: CGFloat) -> Sample { image.colour(x: x, screenY: barMid, height: size.height) }
        XCTAssertTrue(at(edge + copy + gap / 2).matches(midnight.colors.bar), "in the gap: \(at(edge + copy + gap / 2))")
        XCTAssertTrue(at(edge + copy + gap + 1.5).matches(midnight.colors.card), "Retry's box: \(at(edge + copy + gap + 1.5))")
        XCTAssertTrue(at(edge + copy + gap - 0.75).matches(midnight.colors.bar), "Retry starts early: \(at(edge + copy + gap - 0.75))")
    }

    // MARK: - Keyboard

    /// ⌘C copies a recognised entry and Esc closes, as today.
    func testCommandCCopiesAndEscapeCloses() throws {
        var copies = 0
        var closes = 0
        let view = ThemedHistoryReaderView(
            date: Self.sampleDate, language: "en", text: Self.sampleText,
            isRecognized: true, canRetry: false,
            onCopy: { copies += 1 }, onRetry: {}, onClose: { closes += 1 }
        )
        let window = keyWindow(hosting: view)
        defer { window.close() }

        XCTAssertTrue(window.performKeyEquivalent(with: key("c", code: 8, modifiers: .command)), "⌘C was not taken")
        settle(window.contentView!)
        XCTAssertEqual(copies, 1, "⌘C did not copy")
        XCTAssertTrue(window.performKeyEquivalent(with: key("\u{1b}", code: 53, modifiers: [])), "Esc was not taken")
        settle(window.contentView!)
        XCTAssertEqual(closes, 1, "Esc did not close")
        XCTAssertEqual(copies, 1, "Esc copied")
    }

    // MARK: - A theme switch

    /// The hosted view follows a switch at the same size.
    func testAThemeSwitchMovesNothingInTheView() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) { reader() })
        settle(host)
        let before = host.fittingSize
        store.theme = .daylight
        settle(host)
        XCTAssertEqual(host.fittingSize, before)
        store.theme = .midnight
        settle(host)
        XCTAssertEqual(host.fittingSize, before)
    }

    // MARK: - The window

    /// Settings' chrome: the system titlebar, see-through over the window's 02, the theme's
    /// appearance, and the tokens' content size and minimum.
    func testTheWindowTakesTheChromeAndSizeFromTheTokens() {
        let window = makeWindow()
        ThemedHistoryReaderWindow.configure(window, tokens: midnight)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.backgroundColor, midnight.colors.surface.nsColor)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, midnight.historyReader.contentSize)
        XCTAssertEqual(window.contentMinSize, midnight.historyReader.minContentSize)
    }

    /// A theme switch with the window open gives it the theme's colours again and moves
    /// and resizes nothing.
    func testAThemeSwitchRepaintsTheWindowAndMovesNothing() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let window = makeWindow()
        ThemedHistoryReaderWindow.configure(window, tokens: source.tokens)
        let follower = ThemedHistoryReaderWindow.follow(source, window: window)
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
    private static let sampleDate = "19 Sep 2026 at 9:22"

    private func reader(
        language: String? = "en",
        text: String? = nil,
        isRecognized: Bool = true,
        canRetry: Bool = false
    ) -> ThemedHistoryReaderView {
        ThemedHistoryReaderView(
            date: Self.sampleDate, language: language, text: text ?? Self.sampleText,
            isRecognized: isRecognized, canRetry: canRetry,
            onCopy: {}, onRetry: {}, onClose: {}
        )
    }

    private func render(_ view: ThemedHistoryReaderView) throws -> Snapshot {
        try XCTUnwrap(Snapshot.render(
            ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view },
            size: midnight.historyReader.contentSize
        ))
    }

    /// Where the card should be, in points from the top: under the date line and the gap,
    /// down to the padding above the action bar's divider.
    private func cardGeometry() throws -> (top: CGFloat, bottom: CGFloat) {
        let reader = midnight.historyReader
        let date = try reference(Text(Self.sampleDate).font(reader.date.font), in: midnight.colors.secondaryText)
        let top = reader.dividerWidth + reader.contentPaddingVertical + date.size.height + reader.contentGap
        let bottom = reader.contentSize.height - midnight.sizes.actionBar - reader.dividerWidth - reader.contentPaddingVertical
        return (top, bottom)
    }

    /// The drawn push button's width with `title`.
    private func buttonWidth(_ title: String) throws -> CGFloat {
        let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) {
            ThemedPushButton(title) {}.fixedSize()
        })
        return host.fittingSize.width
    }

    /// A view drawn alone in `colour` on 02 at its own size: its size and where its ink
    /// lies in it, in points from its top-left corner.
    private func reference(_ content: some View, in colour: ThemeColor) throws -> (size: CGSize, ink: CGRect) {
        let probe = NSHostingView(rootView: content.fixedSize())
        let size = probe.fittingSize
        let drawn = content.foregroundStyle(colour.color).fixedSize()
            .frame(width: size.width, height: size.height)
            .background(midnight.colors.surface.color)
        let image = try XCTUnwrap(Snapshot.render(drawn, size: size))
        let ink = try XCTUnwrap(image.inkBounds(in: CGRect(origin: .zero, size: size), background: midnight.colors.surface))
        return (size, ink)
    }

    private func keyWindow(hosting view: ThemedHistoryReaderView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: midnight.historyReader.contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view })
        window.makeKeyAndOrderFront(nil)
        settle(window.contentView!)
        return window
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable, .resizable],
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

    /// The top edge of every row holding ink in `rect`, top to bottom.
    @MainActor
    func inkRows(in rect: CGRect, background: ThemeColor) -> [CGFloat]? {
        let rows = Set(pixels(in: rect).filter { isInk($0.colour, background: background) }.map(\.y)).sorted()
        return rows.isEmpty ? nil : rows
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
}
