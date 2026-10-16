import AppKit
import Combine
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The permissions onboarding window (#186): the welcome window's chrome over `surface`, a
/// `divider` line under the titlebar, then, padded 16 / 20 / 20, the 13/600 heading, 4
/// below it the 12 subtitle in `secondaryText` at 1.45, and 14 below that two `card`s 10
/// apart. A card, padded 12 / 14 / 14: the leading glyph in `secondaryText`, then the
/// title row (13 title, the badge at the right), 3 below the 12 message, 10 below the
/// push button. Needs access: the failure hatch on `failureFill` inside a dashed
/// `mutedEdge`. Granted: the `success` dot and the word in `secondaryText`, the button
/// disabled. Every value from the tokens, the same in both themes.
@MainActor
final class PermissionsThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    // MARK: - Tokens

    /// `docs/design/dark/master-design.dc.html`, "7a · PERMISSIONS · 520", and the
    /// owner's leading glyph (#186).
    func testTheMetricsAreTheDesigns() {
        let metrics = midnight.permissions
        // "width:520px".
        XCTAssertEqual(metrics.contentWidth, 520)
        // The body, "padding:16px 20px 20px".
        XCTAssertEqual(metrics.paddingTop, 16)
        XCTAssertEqual(metrics.paddingHorizontal, 20)
        XCTAssertEqual(metrics.paddingBottom, 20)
        // The subtitle, "margin-top:4px".
        XCTAssertEqual(metrics.subtitleGap, 4)
        // The cards, "margin-top:14px;display:flex;flex-direction:column;gap:10px".
        XCTAssertEqual(metrics.cardsGap, 14)
        XCTAssertEqual(metrics.cardGap, 10)
        // A card, "padding:12px 14px 14px".
        XCTAssertEqual(metrics.cardPaddingTop, 12)
        XCTAssertEqual(metrics.cardPaddingHorizontal, 14)
        XCTAssertEqual(metrics.cardPaddingBottom, 14)
        // The title row, "gap:8px"; the message, "margin-top:3px"; the button,
        // "margin-top:10px".
        XCTAssertEqual(metrics.headerGap, 8)
        XCTAssertEqual(metrics.messageGap, 3)
        XCTAssertEqual(metrics.buttonGap, 10)
        // The Granted badge, "gap:6px".
        XCTAssertEqual(metrics.grantedDotGap, 6)
        // Not in the design: the owner's glyph, 18 in a 22 column, 12 before the text.
        XCTAssertEqual(metrics.glyph, ThemeFont(size: 18, weight: .regular))
        XCTAssertEqual(metrics.glyphColumn, 22)
        XCTAssertEqual(metrics.glyphGap, 12)
    }

    /// The shared tokens the window borrows.
    func testTheSharedTokensAreTheDesigns() {
        // The heading "13px;font-weight:600", the card title "13px", the texts "12px;
        // line-height:1.45", the badge "11px".
        XCTAssertEqual(midnight.type.title, ThemeFont(size: 13, weight: .semibold))
        XCTAssertEqual(midnight.type.body, ThemeFont(size: 13, weight: .regular))
        XCTAssertEqual(midnight.type.small, ThemeFont(size: 12, weight: .regular))
        XCTAssertEqual(midnight.type.bodyLineHeight, 1.45)
        XCTAssertEqual(midnight.type.caption, ThemeFont(size: 11, weight: .regular))
        // The card, "background:#23262D;border-radius:8px".
        XCTAssertEqual(midnight.colors.card, .hex(0x23262D))
        XCTAssertEqual(midnight.radii.card, 8)
        // The badge, "line-height:18px;padding:0 8px;border-radius:6px;border:1px dashed
        // #5A6070;background-color:#1E2126".
        XCTAssertEqual(midnight.sizes.keycap, 18)
        XCTAssertEqual(midnight.controlMetrics.badgePadding, 8)
        XCTAssertEqual(midnight.radii.control, 6)
        XCTAssertEqual(midnight.colors.mutedEdge, .hex(0x5A6070))
        XCTAssertEqual(midnight.colors.failureFill, .hex(0x1E2126))
        // "repeating-linear-gradient(135deg,rgba(138,144,158,0.18) 0 4px, … 4px 9px)".
        XCTAssertEqual(midnight.colors.failureHatch, .hex(0x8A909E, opacity: 0.18))
        XCTAssertEqual(midnight.controlMetrics.failureHatchStripe, 4)
        XCTAssertEqual(midnight.controlMetrics.failureHatchPeriod, 9)
        // The dot, "width:6px;height:6px;background:#78BE20".
        XCTAssertEqual(midnight.sizes.dot, 6)
        XCTAssertEqual(midnight.colors.success, .hex(0x78BE20))
        // The button, "line-height:24px;padding:0 10px;background:#2E323B;border:1px
        // solid #3B4150"; granted, "background:transparent", "color:#9BA1AF".
        XCTAssertEqual(midnight.sizes.control, 26)
        XCTAssertEqual(midnight.controlMetrics.horizontalPadding, 10)
        XCTAssertEqual(midnight.colors.raisedControl, .hex(0x2E323B))
        XCTAssertEqual(midnight.colors.edge, .hex(0x3B4150))
        XCTAssertEqual(midnight.colors.secondaryText, .hex(0x9BA1AF))
    }

    func testBothThemesShareEverySize() {
        XCTAssertEqual(ThemeTokens.daylight.permissions, midnight.permissions)
    }

    // MARK: - The drawn view

    func testTheViewIsTheContentWidth() {
        for theme in AppTheme.allCases {
            for state in State.allCases {
                XCTAssertEqual(Snapshot.fittingSize(root(theme: theme, state: state)).width, midnight.permissions.contentWidth, "\(theme) \(state)")
            }
        }
    }

    /// Top to bottom: the divider, 16, the heading's line, 4, the subtitle's line at 1.45
    /// × 12, 14, two cards 10 apart, 20. A card: 12, the 18 title row, 3, the message's
    /// line, 10, the 26 button, 14. Read from the pixels: the two `card` runs down a
    /// column inside the cards' rounding, right of the badge.
    func testTheCardsAreWhereTheStackPutsThem() throws {
        let layout = Layout(midnight)
        for theme in AppTheme.allCases {
            for state in State.allCases {
                let read = try render(theme: theme, state: state)
                XCTAssertEqual(read.size.height, layout.height, accuracy: 1, "\(theme) \(state) height")
                let cards = read.cardRuns()
                XCTAssertEqual(cards.count, 2, "\(theme) \(state): \(cards)")
                guard cards.count == 2 else { continue }
                XCTAssertEqual(cards[0].top, layout.firstCardTop, accuracy: 1, "\(theme) \(state) first card top")
                XCTAssertEqual(cards[0].bottom - cards[0].top, layout.cardHeight, accuracy: 1, "\(theme) \(state) first card height")
                XCTAssertEqual(cards[1].top - cards[0].bottom, midnight.permissions.cardGap, accuracy: 0.5, "\(theme) \(state) card gap")
                XCTAssertEqual(cards[1].bottom - cards[1].top, layout.cardHeight, accuracy: 1, "\(theme) \(state) second card height")
                XCTAssertEqual(read.size.height - cards[1].bottom, midnight.permissions.paddingBottom, accuracy: 0.5, "\(theme) \(state) bottom padding")
                XCTAssertTrue(read.at(x: 4, y: read.size.height / 2).matches(theme.tokens.colors.surface), "\(theme) \(state) surface")
                XCTAssertTrue(read.at(x: 4, y: read.step / 2).matches(theme.tokens.colors.divider), "\(theme) \(state) divider")
            }
        }
    }

    /// Each card's glyph is `secondaryText` in both states, inside the glyph column and
    /// within the title row's height.
    func testTheGlyphsAreSecondaryTextInBothStates() throws {
        let layout = Layout(midnight)
        for theme in AppTheme.allCases {
            let colors = theme.tokens.colors
            for state in State.allCases {
                let read = try render(theme: theme, state: state)
                for card in 0..<2 {
                    let rowTop = layout.cardTop(card) + midnight.permissions.cardPaddingTop
                    let pixels = read.pixels(
                        x: layout.glyphLeft..<(layout.glyphLeft + midnight.permissions.glyphColumn),
                        y: (rowTop - 3)..<(rowTop + midnight.sizes.keycap + 3)
                    )
                    let drawn = pixels.filter { !$0.sample.matches(colors.card) }
                    XCTAssertFalse(drawn.isEmpty, "\(theme) \(state) card \(card): no glyph")
                    XCTAssertTrue(drawn.contains { $0.sample.matches(colors.secondaryText) }, "\(theme) \(state) card \(card): the glyph is not 07")
                    for other in [colors.primaryText, colors.success, colors.brand] {
                        XCTAssertFalse(drawn.contains { $0.sample.matches(other) }, "\(theme) \(state) card \(card): the glyph is \(other)")
                    }
                    let top = try XCTUnwrap(drawn.map(\.y).min())
                    let bottom = try XCTUnwrap(drawn.map(\.y).max())
                    XCTAssertGreaterThanOrEqual(top, rowTop - 0.5, "\(theme) \(state) card \(card): the glyph is above the title row")
                    XCTAssertLessThanOrEqual(bottom, rowTop + midnight.sizes.keycap + 0.5, "\(theme) \(state) card \(card): the glyph is below the title row")
                }
            }
        }
    }

    /// A card that needs access shows its badge at the card's right text edge and an
    /// enabled button on `raisedControl`; a granted card a disabled button, its fill the
    /// card's.
    func testTheCardsFollowTheirState() throws {
        let layout = Layout(midnight)
        for theme in AppTheme.allCases {
            let colors = theme.tokens.colors
            for state in State.allCases {
                let read = try render(theme: theme, state: state)
                for card in 0..<2 {
                    let granted = state.granted[card]
                    let fill = read.at(x: layout.buttonLeft + 4, y: layout.buttonMiddle(card))
                    let edge = read.at(x: layout.buttonLeft + midnight.controlMetrics.edgeWidth / 2, y: layout.buttonMiddle(card))
                    XCTAssertTrue(fill.matches(granted ? colors.card : colors.raisedControl), "\(theme) \(state) card \(card) button fill: \(fill)")
                    XCTAssertTrue(edge.matches(colors.edge), "\(theme) \(state) card \(card) button edge: \(edge)")
                    // Just inside the badge's top edge, left of the card's right text edge.
                    let badge = read.at(x: layout.textRight - 4, y: layout.cardTop(card) + midnight.permissions.cardPaddingTop + 1.75)
                    if granted {
                        XCTAssertTrue(badge.matches(colors.card), "\(theme) \(state) card \(card): a granted card has a box: \(badge)")
                    } else {
                        XCTAssertFalse(badge.matches(colors.card), "\(theme) \(state) card \(card): no badge at the right: \(badge)")
                    }
                }
            }
        }
    }

    // MARK: - The badges

    /// Needs access: 18 tall, the failure hatch on `failureFill`, a dashed `mutedEdge`.
    func testTheNeedsAccessBadgeIsTheHatchInADashedEdge() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let root = ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { ThemedPermissionBadge(isGranted: false) }
            let size = Snapshot.fittingSize(root)
            XCTAssertEqual(size.height, tokens.sizes.keycap, "\(theme)")
            let shot = try XCTUnwrap(Snapshot.render(root, size: size))
            let step = 1 / shot.scale
            let edgeWidth = tokens.controlMetrics.edgeWidth
            let radius = tokens.radii.control

            // The left edge, clear of the rounded corners: dashes and gaps.
            var on = 0, off = 0
            var y = radius
            while y < size.height - radius {
                let sample = shot.colour(x: edgeWidth / 2, screenY: size.height - y, height: size.height)
                if sample.isNearer(to: tokens.colors.mutedEdge, than: tokens.colors.failureFill) { on += 1 } else { off += 1 }
                y += step
            }
            XCTAssertGreaterThan(on, 0, "\(theme): no edge")
            XCTAssertGreaterThan(off, 0, "\(theme): the edge is not dashed")

            // Just inside the top and bottom edges, clear of the text: the fill and the
            // stripes over it.
            var fill = 0, stripe = 0
            for rowY in [edgeWidth + 0.75, size.height - edgeWidth - 0.75] {
                var x = radius
                while x < size.width - radius {
                    let sample = shot.colour(x: x, screenY: size.height - rowY, height: size.height)
                    if sample.matches(tokens.colors.failureFill) { fill += 1 } else { stripe += 1 }
                    x += step
                }
            }
            XCTAssertGreaterThan(fill, 0, "\(theme): no failure fill")
            XCTAssertGreaterThan(stripe, 0, "\(theme): no hatch")
        }
    }

    /// The words: "Needs access" in `primaryText` (the design's #E8EAEF on the hatch),
    /// "Granted" in `secondaryText` (#9BA1AF). Read inside each badge's text box, clear of
    /// the edge and the dot.
    func testTheBadgeWordsTakeTheirTextColours() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let colors = tokens.colors
            for (isGranted, word, other) in [(false, colors.primaryText, colors.secondaryText), (true, colors.secondaryText, colors.primaryText)] {
                let root = ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { ThemedPermissionBadge(isGranted: isGranted) }
                let size = Snapshot.fittingSize(root)
                let shot = try XCTUnwrap(Snapshot.render(root, size: size))
                let step = 1 / shot.scale
                let left = isGranted
                    ? tokens.sizes.dot + tokens.permissions.grantedDotGap
                    : tokens.controlMetrics.badgePadding
                let right = isGranted ? size.width : size.width - tokens.controlMetrics.badgePadding
                let inset = tokens.controlMetrics.edgeWidth + 1
                var text: [Sample] = []
                var y = inset
                while y < size.height - inset {
                    var x = left
                    while x < right {
                        text.append(shot.colour(x: x, screenY: y, height: size.height))
                        x += step
                    }
                    y += step
                }
                let name = isGranted ? "Granted" : "Needs access"
                XCTAssertTrue(text.contains { $0.matches(word) }, "\(theme) \(name): the word is not \(word)")
                // One way round only for the 08 word: the edge of an 08 letter on the
                // dark hatch passes through 07.
                if isGranted {
                    XCTAssertFalse(text.contains { $0.matches(other) }, "\(theme) \(name): the word is \(other)")
                }
            }
        }
    }

    /// Granted: 18 tall, the 6 `success` dot, 6 before the word in `secondaryText`, no box.
    func testTheGrantedBadgeIsTheDotAndAGreyWord() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let root = ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { ThemedPermissionBadge(isGranted: true) }
            let size = Snapshot.fittingSize(root)
            XCTAssertEqual(size.height, tokens.sizes.keycap, "\(theme)")
            let shot = try XCTUnwrap(Snapshot.render(root, size: size))
            let step = 1 / shot.scale
            let middle = size.height / 2
            let dot = shot.colour(x: tokens.sizes.dot / 2, screenY: middle, height: size.height)
            XCTAssertTrue(dot.matches(tokens.colors.success), "\(theme) dot: \(dot)")

            var word: [Sample] = []
            var x = tokens.sizes.dot + tokens.permissions.grantedDotGap
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    word.append(shot.colour(x: x, screenY: y, height: size.height))
                    y += step
                }
                x += step
            }
            XCTAssertTrue(word.contains { $0.matches(tokens.colors.secondaryText) }, "\(theme): the word is not 07")
            XCTAssertFalse(word.contains { $0.matches(tokens.colors.primaryText) }, "\(theme): the word is 08")
            // Between the dot and the word: nothing drawn.
            let gap = shot.colour(x: tokens.sizes.dot + 1, screenY: middle, height: size.height)
            XCTAssertEqual(gap.colour?.alphaComponent ?? 0, 0, accuracy: 0.05, "\(theme): the gap is drawn: \(gap)")
            // No box: the top-left corner is clear.
            let corner = shot.colour(x: tokens.sizes.dot + 1, screenY: size.height - step / 2, height: size.height)
            XCTAssertEqual(corner.colour?.alphaComponent ?? 0, 0, accuracy: 0.05, "\(theme): a box: \(corner)")
        }
    }

    // MARK: - The button

    /// On a card the push button lies on `raisedControl` (the sheet's 04, "a control
    /// sitting on a 03 card"), its label `primaryText`. Disabled it keeps its place and its
    /// `edge`, drops the fill and greys the label to `secondaryText`.
    func testThePushButtonOnACardAndDisabled() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let colors = tokens.colors
            let source = ThemeTokensSource(theme: theme)
            let enabled = ThemedRoot("test", source: source) {
                ThemedPushButton("Open System Settings", onCard: true) {}.fixedSize().background(colors.card.color)
            }
            let disabled = ThemedRoot("test", source: source) {
                ThemedPushButton("Open System Settings", onCard: true) {}.fixedSize().disabled(true).background(colors.card.color)
            }
            let size = Snapshot.fittingSize(enabled)
            XCTAssertEqual(size.height, tokens.sizes.control, "\(theme)")
            XCTAssertEqual(Snapshot.fittingSize(disabled), size, "\(theme): disabling moves the button")

            for (name, view, fill, label) in [
                ("enabled", AnyView(enabled), colors.raisedControl, colors.primaryText),
                ("disabled", AnyView(disabled), colors.card, colors.secondaryText),
            ] {
                let shot = try XCTUnwrap(Snapshot.render(view, size: size))
                let middle = size.height / 2
                let edge = shot.colour(x: tokens.controlMetrics.edgeWidth / 2, screenY: middle, height: size.height)
                let inside = shot.colour(x: 4, screenY: middle, height: size.height)
                XCTAssertTrue(edge.matches(colors.edge), "\(theme) \(name) edge: \(edge)")
                XCTAssertTrue(inside.matches(fill), "\(theme) \(name) fill: \(inside)")
                let step = 1 / shot.scale
                var text: [Sample] = []
                var x = tokens.controlMetrics.horizontalPadding
                while x < size.width - tokens.controlMetrics.horizontalPadding {
                    text.append(shot.colour(x: x, screenY: middle, height: size.height))
                    x += step
                }
                XCTAssertTrue(text.contains { $0.matches(label) }, "\(theme) \(name): the label is not \(label)")
                // Only one way round: the edge of an 08 letter on 04 passes through 07.
                if label != colors.primaryText {
                    XCTAssertFalse(text.contains { $0.matches(colors.primaryText) }, "\(theme) \(name): the label is 08")
                }
            }
        }
    }

    /// Off a card the push button keeps its `card` fill.
    func testThePushButtonOffACardKeepsTheCardFill() throws {
        for theme in AppTheme.allCases {
            let tokens = theme.tokens
            let root = ThemedRoot("test", source: ThemeTokensSource(theme: theme)) {
                ThemedPushButton("Later") {}.fixedSize().background(tokens.colors.surface.color)
            }
            let size = Snapshot.fittingSize(root)
            let shot = try XCTUnwrap(Snapshot.render(root, size: size))
            let inside = shot.colour(x: 4, screenY: size.height / 2, height: size.height)
            XCTAssertTrue(inside.matches(tokens.colors.card), "\(theme): \(inside)")
        }
    }

    // MARK: - A theme switch

    /// A theme switch with the view open repaints it and moves nothing.
    func testAThemeSwitchRepaintsTheViewAndMovesNothing() throws {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view(.needsBoth) })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        settle(host)
        let size = host.fittingSize
        let before = try Read(host: host, size: size, tokens: source.tokens).cardRuns()
        XCTAssertEqual(before.count, 2)

        for theme in [AppTheme.daylight, .midnight] {
            store.theme = theme
            settle(host)
            XCTAssertEqual(host.fittingSize, size, "\(theme)")
            let read = try Read(host: host, size: size, tokens: theme.tokens)
            XCTAssertTrue(read.at(x: 4, y: size.height / 2).matches(theme.tokens.colors.surface), "\(theme) surface")
            let after = read.cardRuns()
            XCTAssertEqual(after.count, before.count, "\(theme)")
            for (a, b) in zip(after, before) {
                XCTAssertEqual(a.top, b.top, accuracy: 0.01, "\(theme)")
                XCTAssertEqual(a.bottom, b.bottom, accuracy: 0.01, "\(theme)")
            }
        }
    }

    // MARK: - The window

    /// The permissions window's chrome: content at the drawn view's fitting size, the
    /// titlebar see-through over `surface`, the theme's appearance; a theme switch with
    /// the window open repaints it and moves and resizes nothing.
    func testAThemeSwitchRepaintsTheWindowAndMovesNothing() {
        let (store, source, cleanup) = followedSource()
        defer { cleanup() }
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view(.microphoneGranted) })
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
        XCTAssertEqual(window.contentLayoutRect.width, midnight.permissions.contentWidth)

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

    /// The two states the design draws.
    private enum State: CaseIterable, CustomStringConvertible {
        /// 7a: both need access, the microphone not yet asked.
        case needsBoth
        /// 7b: the microphone granted, Accessibility needs access.
        case microphoneGranted

        var granted: [Bool] {
            switch self {
            case .needsBoth: return [false, false]
            case .microphoneGranted: return [true, false]
            }
        }

        var description: String {
            switch self {
            case .needsBoth: return "needs both"
            case .microphoneGranted: return "microphone granted"
            }
        }
    }

    private func view(_ state: State) -> ThemedPermissionsView {
        ThemedPermissionsView(
            microphone: .init(
                isGranted: state.granted[0],
                buttonTitle: state == .needsBoth ? "Allow Microphone" : "Open System Settings",
                action: {}
            ),
            accessibility: .init(isGranted: state.granted[1], buttonTitle: "Open System Settings", action: {})
        )
    }

    private func root(theme: AppTheme, state: State) -> some View {
        ThemedRoot("test", source: ThemeTokensSource(theme: theme)) { view(state) }
    }

    /// Where the design puts things, from the tokens, in points from the view's top.
    private struct Layout {
        let tokens: ThemeTokens

        init(_ tokens: ThemeTokens) { self.tokens = tokens }

        private var metrics: ThemeTokens.PermissionsMetrics { tokens.permissions }
        private var smallLine: CGFloat { tokens.type.small.size * CGFloat(tokens.type.bodyLineHeight ?? 1) }

        var firstCardTop: CGFloat {
            let heading = NSLayoutManager().defaultLineHeight(for: tokens.type.title.nsFont)
            return tokens.controlMetrics.edgeWidth + metrics.paddingTop + heading + metrics.subtitleGap + smallLine + metrics.cardsGap
        }

        var cardHeight: CGFloat {
            metrics.cardPaddingTop + tokens.sizes.keycap + metrics.messageGap + smallLine
                + metrics.buttonGap + tokens.sizes.control + metrics.cardPaddingBottom
        }

        var height: CGFloat { cardTop(1) + cardHeight + metrics.paddingBottom }

        func cardTop(_ index: Int) -> CGFloat { firstCardTop + CGFloat(index) * (cardHeight + metrics.cardGap) }

        var glyphLeft: CGFloat { metrics.paddingHorizontal + metrics.cardPaddingHorizontal }
        var buttonLeft: CGFloat { glyphLeft + metrics.glyphColumn + metrics.glyphGap }
        var textRight: CGFloat { metrics.contentWidth - metrics.paddingHorizontal - metrics.cardPaddingHorizontal }

        func buttonMiddle(_ index: Int) -> CGFloat {
            cardTop(index) + cardHeight - metrics.cardPaddingBottom - tokens.sizes.control / 2
        }
    }

    /// A render read in view points from the top left.
    private struct Read {
        let shot: Snapshot
        let size: CGSize
        let tokens: ThemeTokens

        var step: CGFloat { 1 / shot.scale }

        init(shot: Snapshot, size: CGSize, tokens: ThemeTokens) {
            self.shot = shot
            self.size = size
            self.tokens = tokens
        }

        init(host: NSView, size: CGSize, tokens: ThemeTokens) throws {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            self.init(shot: Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / size.width), size: size, tokens: tokens)
        }

        func at(x: CGFloat, y: CGFloat) -> Sample {
            shot.colour(x: x, screenY: size.height - y, height: size.height)
        }

        func pixels(x: Range<CGFloat>, y: Range<CGFloat>) -> [(x: CGFloat, y: CGFloat, sample: Sample)] {
            var result: [(x: CGFloat, y: CGFloat, sample: Sample)] = []
            var py = y.lowerBound
            while py < y.upperBound {
                var px = x.lowerBound
                while px < x.upperBound {
                    result.append((px, py, at(x: px, y: py)))
                    px += step
                }
                py += step
            }
            return result
        }

        /// The runs of `card` down a column inside the cards' rounding at their right,
        /// clear of the texts and the badge, below the divider (which is the same colour).
        @MainActor
        func cardRuns() -> [(top: CGFloat, bottom: CGFloat)] {
            let x = tokens.permissions.contentWidth - tokens.permissions.paddingHorizontal - tokens.radii.card
            var runs: [(top: CGFloat, bottom: CGFloat)] = []
            var start: CGFloat?
            var y = tokens.controlMetrics.edgeWidth + step
            while y < size.height {
                let isCard = at(x: x, y: y + step / 2).matches(tokens.colors.card)
                if isCard, start == nil { start = y }
                if !isCard, let top = start { runs.append((top, y)); start = nil }
                y += step
            }
            if let top = start { runs.append((top, size.height)) }
            return runs
        }
    }

    private func render(theme: AppTheme, state: State) throws -> Read {
        let root = root(theme: theme, state: state)
        let size = Snapshot.fittingSize(root)
        let shot = try XCTUnwrap(Snapshot.render(root, size: size))
        return Read(shot: shot, size: size, tokens: theme.tokens)
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
