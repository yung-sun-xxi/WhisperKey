import AppKit
import SwiftUI

/// The "?" after a row title whose meaning is not obvious (#220): `questionmark.circle`
/// in `small`, `secondaryText` at rest and `primaryText` under the pointer. Hovering it
/// shows `ThemedHintBubble` with the hint, in place of the system's yellow tooltip, so the
/// explanation looks like the rest of the theme.
///
/// The bubble is a borderless child window of the row's window rather than an overlay
/// inside it: a row near the bottom of the Settings window would otherwise have its bubble
/// cut off at the window's edge, and a SwiftUI `.popover` draws the system's own material
/// and arrow around the content instead of the card.
public struct ThemedHintIcon: View {
    private let text: AttributedString
    @Environment(\.themeTokens) private var tokens
    @State private var isHovered = false
    @State private var anchor = ThemedHintAnchor()

    public init(_ text: AttributedString) {
        self.text = text
    }

    /// `markdown` with inline syntax only (`**bold**`), its whitespace kept. Shown plain
    /// rather than not at all if it ever fails to parse.
    public init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self.text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    public var body: some View {
        Image(systemName: "questionmark.circle")
            .font(tokens.type.small.font)
            .foregroundStyle((isHovered ? tokens.colors.primaryText : tokens.colors.secondaryText).color)
            .background(ThemedHintAnchorView(anchor: anchor))
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    ThemedHintBubbleWindow.shared.show(text, tokens: tokens, under: anchor.view)
                } else {
                    ThemedHintBubbleWindow.shared.hide()
                }
            }
            .onDisappear {
                guard isHovered else { return }
                isHovered = false
                ThemedHintBubbleWindow.shared.hide()
            }
            .accessibilityLabel("Help")
            .accessibilityValue(String(text.characters))
    }
}

/// The hint as drawn: its text in `caption` and `primaryText` on a `card` fill with an
/// `edge` outline and the card's radius, as wide as the text up to
/// `hint.bubbleMaxWidth`, past which the text wraps.
public struct ThemedHintBubble: View {
    private let text: AttributedString
    @Environment(\.themeTokens) private var tokens

    public init(_ text: AttributedString) {
        self.text = text
    }

    public var body: some View {
        let hint = tokens.hint
        let shape = RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous)
        Text(text)
            .font(tokens.type.caption.font)
            .foregroundStyle(tokens.colors.primaryText.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, hint.bubblePaddingHorizontal)
            .padding(.vertical, hint.bubblePaddingVertical)
            .background(tokens.colors.card.color, in: shape)
            .overlay(shape.strokeBorder(tokens.colors.edge.color, lineWidth: tokens.controlMetrics.edgeWidth))
    }
}

/// Where the "?" is on screen: the AppKit view behind it, read when the bubble opens.
final class ThemedHintAnchor {
    weak var view: NSView?
}

private struct ThemedHintAnchorView: NSViewRepresentable {
    let anchor: ThemedHintAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// The one hint bubble on screen: a borderless, click-through child window of the row's
/// window, under the "?" and aligned to its leading edge, kept inside the screen's
/// visible frame (above the "?" when there is no room under it).
@MainActor
final class ThemedHintBubbleWindow {
    static let shared = ThemedHintBubbleWindow()

    private var panel: NSPanel?
    private var host: NSHostingController<AnyView>?

    func show(_ text: AttributedString, tokens: ThemeTokens, under anchor: NSView?) {
        hide()
        guard let anchor, let parent = anchor.window else { return }

        let host = NSHostingController(rootView: AnyView(
            ThemedHintBubble(text).environment(\.themeTokens, tokens)
        ))
        let proposal = CGSize(width: tokens.hint.bubbleMaxWidth, height: .greatestFiniteMagnitude)
        let size = host.sizeThatFits(in: proposal)
        let anchorFrame = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame
        let origin = Self.origin(of: size, under: anchorFrame, offset: tokens.hint.bubbleOffset, within: screen)

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        host.view.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host.view
        parent.addChildWindow(panel, ordered: .above)

        self.panel = panel
        self.host = host
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        host = nil
    }

    /// Under the anchor, its leading edge on the anchor's; moved left to stay on screen,
    /// and above the anchor when the screen ends under it.
    static func origin(of size: CGSize, under anchor: CGRect, offset: CGFloat, within screen: CGRect?) -> CGPoint {
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - offset - size.height)
        guard let screen else { return origin }
        if origin.x + size.width > screen.maxX {
            origin.x = screen.maxX - size.width
        }
        origin.x = max(origin.x, screen.minX)
        if origin.y < screen.minY {
            origin.y = anchor.maxY + offset
        }
        return origin
    }
}
