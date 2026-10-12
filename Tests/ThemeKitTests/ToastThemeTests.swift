import AppKit
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// The toast (#167): the design's card on the shared floating-panel shell, every size
/// from the `toast` token group, with the app's close disc overhanging the card's corner
/// in a transparent margin the blur does not cover.
@MainActor
final class ToastThemeTests: XCTestCase {
    private let midnight = ThemeTokens.midnight

    private static let threeLines = "No response from OpenAI within 30 seconds. It may be your network or OpenAI; no response arrived, so WhisperKey cannot tell which"

    // MARK: - Tokens

    func testMidnightToastTokensAreTheDesign() {
        let toast = midnight.toast
        // The design's card: "padding:14px 14px 14px 16px", an 18 glyph column
        // ("padding-top:8px") and "gap:10px", the label 11/400, the message 13/400 at
        // "line-height:1.45" "margin-top:1px", the button "margin-top:10px".
        XCTAssertEqual(toast.padding, 14)
        XCTAssertEqual(toast.leadingPadding, 16)
        XCTAssertEqual(toast.glyphColumn, 18)
        XCTAssertEqual(toast.glyphTop, 8)
        XCTAssertEqual(toast.glyphGap, 10)
        XCTAssertEqual(toast.glyph, ThemeFont(size: 15, weight: .regular))
        XCTAssertEqual(toast.title, ThemeFont(size: 11, weight: .regular))
        XCTAssertEqual(toast.titleGap, 1)
        XCTAssertEqual(toast.message, ThemeFont(size: 13, weight: .regular))
        XCTAssertEqual(toast.messageLineHeight, 1.45)
        XCTAssertEqual(toast.actionGap, 10)
        // The app's own, kept (#167, the owner's decision 2): the 20 disc, its 9/700
        // cross and 0.5 edge, the 10 margin it overhangs into, the card 12 from the
        // screen's right edge and 8 under the menu bar.
        XCTAssertEqual(toast.closeButton, 20)
        XCTAssertEqual(toast.closeGlyph, ThemeFont(size: 9, weight: .bold))
        XCTAssertEqual(toast.closeEdgeWidth, 0.5)
        XCTAssertEqual(toast.margin, 10)
        XCTAssertEqual(toast.screenEdgeInset, 12)
        XCTAssertEqual(toast.menuBarGap, 8)
        XCTAssertEqual(midnight.shadows.closeButton, .drop(color: .hex(0x000000, opacity: 0.18), blur: 3, x: 0, y: 0.5))
    }

    /// The label and the message are the sheet's caption and body.
    func testTheToastsTypeIsTheSheets() {
        XCTAssertEqual(midnight.toast.title, midnight.type.caption)
        XCTAssertEqual(midnight.toast.message, midnight.type.body)
        XCTAssertEqual(midnight.toast.messageLineHeight, midnight.type.bodyLineHeight)
    }

    func testBothThemesShareTheToast() {
        XCTAssertEqual(ThemeTokens.classic.toast, midnight.toast)
        XCTAssertEqual(ThemeTokens.classic.toastWindowWidth, midnight.toastWindowWidth)
    }

    /// The window is the card plus the margin on both sides, and rests where the card used
    /// to: 12 from the right edge (2 for the window, the margin taking the rest) and 8
    /// under the menu bar (0 for the window: the margin is larger).
    func testTheWindowGeometryIsTheCardPlusItsMargin() {
        XCTAssertEqual(midnight.toastWindowWidth, 400)
        XCTAssertEqual(midnight.toastWindowWidth, midnight.panels.toast.width + midnight.toast.margin * 2)
        XCTAssertEqual(midnight.toastWindowRightInset, 2)
        XCTAssertEqual(midnight.toastWindowTopInset, 0)
    }

    func testTheGlyphs() {
        XCTAssertEqual(ThemedToastView.Glyph.microphone.symbolName, "mic")
        XCTAssertEqual(ThemedToastView.Glyph.microphoneSlash.symbolName, "mic.slash")
    }

    // MARK: - Size

    func testTheToastIsTheWindowsWidth() {
        for content in samples {
            XCTAssertEqual(host(content).fittingSize.width, midnight.toastWindowWidth, content.message)
        }
    }

    /// One line of message, no button: the margin, the edge, the padding, the label's
    /// line, the 1 gap and one 1.45 line of 13, and back down.
    func testTheCardIsAsTallAsTheDesignAddsUp() {
        let toast = midnight.toast
        let edge = midnight.panels.toast.edgeWidth
        let label = NSHostingView(rootView: Text("WhisperKey").font(toast.title.font)).fittingSize.height
        let line = toast.message.size * CGFloat(toast.messageLineHeight)
        let expected = 2 * toast.margin + 2 * edge + 2 * toast.padding + label + toast.titleGap + line
        let height = host(Content(message: "No speech detected", glyph: .microphoneSlash, action: nil)).fittingSize.height
        XCTAssertEqual(height, expected, accuracy: 0.5)
    }

    /// Each line of the message adds 13 × 1.45, the body line height, as the design sets it.
    func testTheMessageLinesAreTheBodyLineHeight() {
        let one = host(Content(message: "No speech detected", glyph: .microphoneSlash, action: nil)).fittingSize.height
        let three = host(Content(message: Self.threeLines, glyph: .microphone, action: nil)).fittingSize.height
        let line = midnight.toast.message.size * CGFloat(midnight.toast.messageLineHeight)
        XCTAssertEqual(three - one, 2 * line, accuracy: 1)
    }

    /// The button: the drawn push button, control-tall, 10 under the message.
    func testTheActionAddsTheGapAndAControl() {
        let without = host(Content(message: "Microphone access is required to record", glyph: .microphone, action: nil)).fittingSize.height
        let with = host(Content(message: "Microphone access is required to record", glyph: .microphone, action: "Open Settings")).fittingSize.height
        XCTAssertEqual(with - without, midnight.toast.actionGap + midnight.sizes.control, accuracy: 0.5)
    }

    /// The acceptance's "a theme switch with the surface open moves nothing": the same
    /// hosting view, never rebuilt, follows the switch at the same size.
    func testAThemeSwitchMovesNothing() {
        let suite = "WhisperKey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.theme = .midnight
        let source = ThemeTokensSource()
        source.follow(store)

        for content in samples {
            let host = NSHostingView(rootView: ThemedRoot("test", source: source) { view(content) })
            settle(host)
            let before = host.fittingSize
            store.theme = .classic
            settle(host)
            XCTAssertEqual(host.fittingSize, before, content.message)
            store.theme = .midnight
            settle(host)
            XCTAssertEqual(host.fittingSize, before, content.message)
        }
    }

    // MARK: - What is drawn

    /// The card sits inside a clear margin; its edge is the shell's, its fill the shell's.
    func testTheCardSitsInsideAClearMargin() throws {
        let content = Content(message: "No speech detected", glyph: .microphoneSlash, action: nil)
        let size = host(content).fittingSize
        let image = try render(content, size: size)
        let margin = midnight.toast.margin
        let midY = size.height / 2

        XCTAssertEqual(image.colour(x: margin / 2, screenY: midY, height: size.height).alpha, 0, "the margin is not clear")
        XCTAssertEqual(image.colour(x: size.width - margin / 2, screenY: midY, height: size.height).alpha, 0, "the margin is not clear")
        XCTAssertTrue(image.colour(x: margin + 0.25, screenY: midY, height: size.height).matches(midnight.panels.toast.edge!), "no edge at the card's side")
        guard case let .fill(fill, _) = midnight.panels.toast.background else { return XCTFail("not a fill") }
        XCTAssertTrue(image.colour(x: size.width - margin - 8, screenY: midY, height: size.height).matches(fill), "the card is not the shell's fill")
    }

    /// The glyph is grey: the secondary text, not orange and not in a tinted circle.
    func testTheGlyphIsTheSecondaryText() throws {
        for glyph in [ThemedToastView.Glyph.microphone, .microphoneSlash] {
            let content = Content(message: "No speech detected", glyph: glyph, action: nil)
            let size = host(content).fittingSize
            let image = try render(content, size: size)
            let toast = midnight.toast
            let left = toast.margin + midnight.panels.toast.edgeWidth + toast.leadingPadding
            var grey = 0
            var other = 0
            for x in stride(from: left, to: left + toast.glyphColumn, by: 0.5) {
                for y in stride(from: toast.margin + 2, to: size.height - toast.margin - 2, by: 0.5) {
                    let sample = image.colour(x: x, screenY: y, height: size.height)
                    guard case let .fill(fill, _) = midnight.panels.toast.background else { return XCTFail("not a fill") }
                    if sample.matches(fill) { continue }
                    if sample.isNearer(to: midnight.colors.secondaryText, than: fill) { grey += 1 }
                    if sample.isSaturated { other += 1 }
                }
            }
            XCTAssertGreaterThan(grey, 10, "\(glyph): no grey glyph")
            XCTAssertEqual(other, 0, "\(glyph): coloured pixels in the glyph column")
        }
    }

    /// Across the card: the edge, the 16 padding, the 18 glyph column and the 10 gap, then
    /// the text. Measured on the label's top rows, above the glyph (8 down): the first
    /// drawn point right of the edge is the label's first letter.
    func testTheTextStartsAfterThePaddingTheGlyphColumnAndTheGap() throws {
        let content = Content(message: "No speech detected", glyph: .microphoneSlash, action: nil)
        let size = host(content).fittingSize
        let image = try render(content, size: size)
        let toast = midnight.toast
        let edge = midnight.panels.toast.edgeWidth
        guard case let .fill(fill, _) = midnight.panels.toast.background else { return XCTFail("not a fill") }
        let textLeft = toast.margin + edge + toast.leadingPadding + toast.glyphColumn + toast.glyphGap
        let labelTop = size.height - toast.margin - edge - toast.padding

        var firstInk: CGFloat?
        for x in stride(from: toast.margin + edge + 1, to: textLeft + 10, by: 0.5) {
            let inked = stride(from: labelTop - 1, to: labelTop - toast.glyphTop + 1, by: -0.5).contains { y in
                !image.colour(x: x, screenY: y, height: size.height).matches(fill)
            }
            if inked {
                firstInk = x
                break
            }
        }
        let x = try XCTUnwrap(firstInk, "no label found")
        XCTAssertEqual(x, textLeft, accuracy: 1.5, "the label starts at \(x), the design puts it at \(textLeft)")
    }

    /// The close disc overhangs the card's top-left corner by half and is drawn whole:
    /// the margin keeps the part outside the card. Hidden, it leaves the margin clear.
    func testTheCloseDiscOverhangsTheCornerUnclipped() throws {
        let content = Content(message: "No speech detected", glyph: .microphoneSlash, action: nil)
        let size = host(content).fittingSize
        let margin = midnight.toast.margin
        let radius = midnight.toast.closeButton / 2
        // Left of the disc's centre (the card's corner), outside the card: the disc's fill.
        let x = margin - radius * 0.6
        let y = size.height - margin

        let shown = try render(content, size: size, closeVisible: true)
        XCTAssertTrue(shown.colour(x: x, screenY: y, height: size.height).matches(midnight.colors.card), "\(shown.colour(x: x, screenY: y, height: size.height))")

        let hidden = try render(content, size: size, closeVisible: false)
        XCTAssertEqual(hidden.colour(x: x, screenY: y, height: size.height).alpha, 0, "the hidden disc still draws")
    }

    // MARK: - The chrome covers the card only

    /// The blur behind the window is the card's, inset by the margin; the other panels'
    /// covers their whole window.
    func testTheBlurCoversTheCardNotTheMargin() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        let toast = ThemedPanelChromeView(kind: .toast, contentView: NSView(), source: ThemeTokensSource(theme: .midnight))
        toast.frame = frame
        toast.layoutSubtreeIfNeeded()
        let toastBlur = try XCTUnwrap(toast.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(toastBlur.frame, frame.insetBy(dx: midnight.toast.margin, dy: midnight.toast.margin))

        let quickPaste = ThemedPanelChromeView(kind: .quickPaste, contentView: NSView(), source: ThemeTokensSource(theme: .midnight))
        quickPaste.frame = frame
        quickPaste.layoutSubtreeIfNeeded()
        let quickPasteBlur = try XCTUnwrap(quickPaste.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(quickPasteBlur.frame, frame)
    }

    // MARK: - Helpers

    private struct Content {
        let message: String
        let glyph: ThemedToastView.Glyph
        let action: String?
    }

    private var samples: [Content] {
        [
            Content(message: Self.threeLines, glyph: .microphone, action: "Retry"),
            Content(message: "Microphone access is required to record", glyph: .microphone, action: "Open Settings"),
            Content(message: "No speech detected", glyph: .microphoneSlash, action: nil),
        ]
    }

    private func view(_ content: Content, closeVisible: Bool = false) -> ThemedToastView {
        ThemedToastView(
            glyph: content.glyph,
            message: content.message,
            actionTitle: content.action,
            showsCloseButton: true,
            isCloseButtonVisible: closeVisible,
            onAction: {},
            onDismiss: {}
        )
    }

    private func host(_ content: Content) -> NSHostingView<ThemedRoot<ThemedToastView>> {
        let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view(content) })
        settle(host)
        return host
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }

    private func render(_ content: Content, size: CGSize, closeVisible: Bool = false) throws -> Snapshot {
        try XCTUnwrap(Snapshot.render(
            ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) { view(content, closeVisible: closeVisible) },
            size: size
        ))
    }
}

private extension Sample {
    var alpha: CGFloat { colour?.alphaComponent ?? -1 }

    /// A colour, not a grey: its channels spread more than a grey's antialiasing would.
    var isSaturated: Bool {
        guard let colour, colour.alphaComponent > 0.5 else { return false }
        let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
        return (channels.max()! - channels.min()!) > 0.15
    }
}
