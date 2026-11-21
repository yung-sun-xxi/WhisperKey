import SwiftUI

/// The welcome window's content as drawn (#185): a `divider` line under the titlebar,
/// then on `surface`, padded `welcome.padding` and centred, the "Welcome to WhisperKey!"
/// heading in `type.title`, `welcome.headingGap` below it the line in `type.body` and
/// `primaryText` at the body's line height, wrapping, and `welcome.buttonsGap` below
/// that the buttons, centred as a group `welcome.buttonGap` apart: "Go to Settings", the
/// default button that takes Return, then "Later", a push button.
///
/// Every size is `tokens.welcome` or a shared token; every colour and font a token.
/// Lives in ThemeKit rather than in the app so a test can host it.
public struct ThemedWelcomeView: View {
    @Environment(\.themeTokens) private var tokens
    private let goToSettings: () -> Void
    private let doLater: () -> Void

    /// - Parameters:
    ///   - goToSettings: "Go to Settings", or Return.
    ///   - doLater: "Later".
    public init(goToSettings: @escaping () -> Void, doLater: @escaping () -> Void) {
        self.goToSettings = goToSettings
        self.doLater = doLater
    }

    public var body: some View {
        VStack(spacing: 0) {
            divider
            content
        }
        .frame(width: tokens.welcome.contentWidth)
        .background(tokens.colors.surface.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.controlMetrics.edgeWidth)
    }

    private var content: some View {
        let metrics = tokens.welcome
        return VStack(spacing: 0) {
            Text("Welcome to WhisperKey!")
                .font(tokens.type.title.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            line
                .padding(.top, metrics.headingGap)
            buttons
                .padding(.top, metrics.buttonsGap)
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity)
    }

    /// CSS line height: the extra room between the lines, and half of it above the first
    /// and below the last.
    private var line: some View {
        let lineSpacing = tokens.type.bodyLineHeight.map { tokens.type.body.extraLineSpacing(lineHeight: $0) } ?? 0
        return Text("Go to Settings to set up your preferences, or you can do it later")
            .font(tokens.type.body.font)
            .foregroundStyle(tokens.colors.primaryText.color)
            .multilineTextAlignment(.center)
            .lineSpacing(lineSpacing)
            .padding(.vertical, lineSpacing / 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: tokens.welcome.buttonGap) {
            ThemedDefaultButton("Go to Settings", action: goToSettings)
                .keyboardShortcut(.defaultAction)
                .fixedSize()
            ThemedPushButton("Later", action: doLater)
                .fixedSize()
        }
    }
}
