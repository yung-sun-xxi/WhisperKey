import AppKit
import SwiftUI

/// The toast as drawn (#167): the design's card on the shared floating-panel shell, a grey
/// microphone in its own column, "WhisperKey" over the message, and the action as the
/// drawn push button; plus the app's close disc on the card's top-left corner.
///
/// The card sits inside a clear `toast.margin` on every side, because the disc overhangs
/// the corner by half; the window is that much larger than the card, and its blur covers
/// the card only (`ThemedPanelChromeView`). Every size is `tokens.toast`, the shell's or a
/// shared token; every colour is a token. The wording (the final full stop dropped, the
/// button's title) is the caller's, and so is the hover that shows the disc. Lives in
/// ThemeKit rather than in the app so a test can host it.
public struct ThemedToastView: View {
    /// The glyph in the card's leading column.
    public enum Glyph: Equatable, Sendable {
        /// The microphone.
        case microphone
        /// The microphone crossed out.
        case microphoneSlash

        public var symbolName: String {
            switch self {
            case .microphone: return "mic"
            case .microphoneSlash: return "mic.slash"
            }
        }
    }

    /// How long the close disc takes to fade in and out.
    public static let closeButtonFadeDuration: TimeInterval = 0.12

    @Environment(\.themeTokens) private var tokens
    private let glyph: Glyph
    private let message: String
    private let actionTitle: String?
    private let showsCloseButton: Bool
    private let isCloseButtonVisible: Bool
    private let onAction: () -> Void
    private let onDismiss: () -> Void

    public init(
        glyph: Glyph,
        message: String,
        actionTitle: String?,
        showsCloseButton: Bool,
        isCloseButtonVisible: Bool,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.glyph = glyph
        self.message = message
        self.actionTitle = actionTitle
        self.showsCloseButton = showsCloseButton
        self.isCloseButtonVisible = isCloseButtonVisible
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let toast = tokens.toast
        card
            .overlay(alignment: .topLeading) {
                if showsCloseButton {
                    closeButton
                        .offset(x: -toast.closeButton / 2, y: -toast.closeButton / 2)
                        .opacity(isCloseButtonVisible ? 1 : 0)
                        .animation(.easeOut(duration: Self.closeButtonFadeDuration), value: isCloseButtonVisible)
                }
            }
            .padding(toast.margin)
    }

    private var card: some View {
        let toast = tokens.toast
        let colors = tokens.colors
        // The design's border-box: the padding is inside the shell's edge.
        let edge = PanelKind.toast.shell(in: tokens).edgeWidth
        let lineSpacing = toast.message.extraLineSpacing(lineHeight: toast.messageLineHeight)
        return ThemedPanelShell(.toast) {
            HStack(alignment: .top, spacing: toast.glyphGap) {
                Image(systemName: glyph.symbolName)
                    .font(toast.glyph.font)
                    .foregroundStyle(colors.secondaryText.color)
                    .frame(width: toast.glyphColumn)
                    .padding(.top, toast.glyphTop)

                VStack(alignment: .leading, spacing: 0) {
                    Text("WhisperKey")
                        .font(toast.title.font)
                        .foregroundStyle(colors.secondaryText.color)
                    Text(message)
                        .font(toast.message.font)
                        .foregroundStyle(colors.primaryText.color)
                        // CSS line height: the extra room between the lines, and half of
                        // it above the first and below the last.
                        .lineSpacing(lineSpacing)
                        .padding(.vertical, lineSpacing / 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, toast.titleGap)
                    if let actionTitle {
                        ThemedPushButton(actionTitle, action: onAction)
                            .padding(.top, toast.actionGap)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(
                top: edge + toast.padding,
                leading: edge + toast.leadingPadding,
                bottom: edge + toast.padding,
                trailing: edge + toast.padding
            ))
        }
    }

    /// The app's close control: a small disc on the corner, shown only while the pointer
    /// is over the toast.
    private var closeButton: some View {
        let toast = tokens.toast
        let colors = tokens.colors
        return Button(action: onDismiss) {
            ZStack {
                Circle()
                    .fill(colors.card.color)
                Circle()
                    .strokeBorder(colors.edge.color, lineWidth: toast.closeEdgeWidth)
                Image(systemName: "xmark")
                    .font(toast.closeGlyph.font)
                    .foregroundStyle(colors.secondaryText.color)
            }
            .frame(width: toast.closeButton, height: toast.closeButton)
            .themedShadow(tokens.shadows.closeButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

extension ThemeFont {
    /// What a CSS `line-height` of `multiple` × the size adds to each line beyond the
    /// font's own line height. CSS puts half of it above a line and half below.
    func extraLineSpacing(lineHeight multiple: Double) -> CGFloat {
        let natural = NSLayoutManager().defaultLineHeight(for: nsFont)
        return max(size * CGFloat(multiple) - natural, 0)
    }
}

extension View {
    /// A drop shadow token drawn in SwiftUI; the window server's (`.system`) draws nothing
    /// here.
    @ViewBuilder
    func themedShadow(_ shadow: ThemeShadow) -> some View {
        if case let .drop(color, _, x, y) = shadow, let radius = shadow.swiftUIRadius {
            self.shadow(color: color.color, radius: radius, x: x, y: y)
        } else {
            self
        }
    }
}
