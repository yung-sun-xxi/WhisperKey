import SwiftUI

/// The permissions onboarding window's content as drawn (#186): a `divider` line under the
/// titlebar, then on `surface`, padded `permissions.paddingTop` / `paddingHorizontal` /
/// `paddingBottom`, the "WhisperKey needs permissions" heading in `type.title`,
/// `subtitleGap` below it the subtitle in `type.small` and `secondaryText` at the body's
/// line height, and `cardsGap` below that the Microphone and Accessibility cards,
/// `cardGap` apart.
///
/// A card is a `card` fill at `radii.card` with no edge, padded `cardPaddingTop` /
/// `cardPaddingHorizontal` / `cardPaddingBottom`: the leading glyph in `secondaryText`
/// whatever the state (the owner's decision; the design drops it), then the title row
/// (`type.body` title, the badge at the right), `messageGap` below the message in
/// `type.small` and `secondaryText`, and `buttonGap` below the push button. A granted
/// card keeps its button in place, disabled.
///
/// The view takes plain values so the app maps its permissions onto it and the Debug
/// build's snapshot hook can feed it states of its own. Every size is
/// `tokens.permissions` or a shared token; every colour and font a token. Lives in
/// ThemeKit rather than in the app so a test can host it.
public struct ThemedPermissionsView: View {
    /// One card's state: whether the permission is granted, and its button.
    public struct Card {
        public var isGranted: Bool
        public var buttonTitle: String
        public var action: () -> Void

        public init(isGranted: Bool, buttonTitle: String, action: @escaping () -> Void) {
            self.isGranted = isGranted
            self.buttonTitle = buttonTitle
            self.action = action
        }
    }

    @Environment(\.themeTokens) private var tokens
    private let microphone: Card
    private let accessibility: Card

    public init(microphone: Card, accessibility: Card) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    public var body: some View {
        VStack(spacing: 0) {
            divider
            content
        }
        .frame(width: tokens.permissions.contentWidth)
        .background(tokens.colors.surface.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.controlMetrics.edgeWidth)
    }

    private var content: some View {
        let metrics = tokens.permissions
        return VStack(alignment: .leading, spacing: 0) {
            Text("WhisperKey needs permissions")
                .font(tokens.type.title.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            secondaryLine("Grant both permissions to record from the menu bar hotkey.")
                .padding(.top, metrics.subtitleGap)
            VStack(alignment: .leading, spacing: metrics.cardGap) {
                card(
                    microphone,
                    glyph: "mic",
                    title: "Microphone",
                    message: "Used only while recording after the hotkey starts capture."
                )
                card(
                    accessibility,
                    glyph: "accessibility",
                    title: "Accessibility",
                    message: "Required for the global hotkey to work while other apps are focused."
                )
            }
            .padding(.top, metrics.cardsGap)
        }
        .padding(.top, metrics.paddingTop)
        .padding(.horizontal, metrics.paddingHorizontal)
        .padding(.bottom, metrics.paddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ card: Card, glyph: String, title: String, message: String) -> some View {
        let metrics = tokens.permissions
        return HStack(alignment: .top, spacing: metrics.glyphGap) {
            // As tall as the title row, so its centre is the row's.
            Image(systemName: glyph)
                .font(metrics.glyph.font)
                .foregroundStyle(tokens.colors.secondaryText.color)
                .frame(width: metrics.glyphColumn, height: tokens.sizes.keycap)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: metrics.headerGap) {
                    Text(title)
                        .font(tokens.type.body.font)
                        .foregroundStyle(tokens.colors.primaryText.color)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ThemedPermissionBadge(isGranted: card.isGranted)
                }
                .frame(height: tokens.sizes.keycap)
                secondaryLine(message)
                    .padding(.top, metrics.messageGap)
                ThemedPushButton(card.buttonTitle, onCard: true, action: card.action)
                    .disabled(card.isGranted)
                    .fixedSize()
                    .padding(.top, metrics.buttonGap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, metrics.cardPaddingTop)
        .padding(.horizontal, metrics.cardPaddingHorizontal)
        .padding(.bottom, metrics.cardPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tokens.colors.card.color,
            in: RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous)
        )
    }

    /// `type.small` in `secondaryText` at CSS line height: the extra room between the
    /// lines, and half of it above the first and below the last.
    private func secondaryLine(_ text: String) -> some View {
        let small = tokens.type.small
        let lineSpacing = tokens.type.bodyLineHeight.map { small.extraLineSpacing(lineHeight: $0) } ?? 0
        return Text(text)
            .font(small.font)
            .foregroundStyle(tokens.colors.secondaryText.color)
            .lineSpacing(lineSpacing)
            .padding(.vertical, lineSpacing / 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A permission card's status, `sizes.keycap` tall, in `type.caption`. Needs access: the
/// word in `primaryText`, padded `badgePadding`, on `failureFill` under the failure hatch,
/// inside a dashed `mutedEdge` at `radii.control` — the rejected API key's tones (#105
/// rule 1). Granted: the `sizes.dot` `success` dot, `permissions.grantedDotGap` before
/// the word in `secondaryText` — the Saved badge's. No glyph in either.
public struct ThemedPermissionBadge: View {
    @Environment(\.themeTokens) private var tokens
    private let isGranted: Bool

    public init(isGranted: Bool) {
        self.isGranted = isGranted
    }

    public var body: some View {
        badge
            .font(tokens.type.caption.font)
            .lineLimit(1)
            .frame(height: tokens.sizes.keycap)
            .fixedSize()
    }

    @ViewBuilder private var badge: some View {
        let metrics = tokens.controlMetrics
        let box = RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
        if isGranted {
            HStack(spacing: tokens.permissions.grantedDotGap) {
                Circle()
                    .fill(tokens.colors.success.color)
                    .frame(width: tokens.sizes.dot, height: tokens.sizes.dot)
                Text("Granted")
                    .foregroundStyle(tokens.colors.secondaryText.color)
            }
        } else {
            Text("Needs access")
                .foregroundStyle(tokens.colors.primaryText.color)
                .padding(.horizontal, metrics.badgePadding)
                .frame(height: tokens.sizes.keycap)
                .background {
                    box
                        .fill(tokens.colors.failureFill.color)
                        .overlay(ThemedFailureHatch().clipShape(box))
                }
                .overlay(
                    box.strokeBorder(
                        tokens.colors.mutedEdge.color,
                        style: StrokeStyle(lineWidth: metrics.edgeWidth, dash: metrics.failureDash)
                    )
                )
        }
    }
}
