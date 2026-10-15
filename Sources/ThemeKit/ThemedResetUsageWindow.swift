import AppKit
import Combine

/// The Reset usage window's chrome (#183): Settings' — the system titlebar, see-through
/// over the window's `surface`, and the theme's appearance, so the titlebar matches the
/// palette. The window's width is `tokens.resetUsage.contentWidth`; its height is the
/// drawn view's, which the caller sets from the hosting view.
///
/// Lives in ThemeKit rather than in the app so a test can build a window, configure it,
/// switch the theme and read back what the window took.
@MainActor
public enum ThemedResetUsageWindow {
    /// The chrome and the current colours. Called once, before the window is placed.
    public static func configure(_ window: NSWindow, tokens: ThemeTokens) {
        window.titlebarAppearsTransparent = true
        applyTheme(tokens, to: window)
    }

    /// The theme's colours and appearance. Nothing else: the themes differ only in
    /// colours, so a switch moves and resizes nothing.
    public static func applyTheme(_ tokens: ThemeTokens, to window: NSWindow) {
        window.backgroundColor = tokens.colors.surface.nsColor
        window.appearance = tokens.windowAppearance.nsAppearance
    }

    /// Re-applies the theme on every switch while the window is kept. Keep the returned
    /// value for as long as the window lives.
    public static func follow(_ source: ThemeTokensSource, window: NSWindow) -> AnyCancellable {
        source.$tokens
            .removeDuplicates()
            .sink { [weak window] tokens in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    applyTheme(tokens, to: window)
                }
            }
    }
}
