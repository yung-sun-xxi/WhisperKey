import AppKit
import Combine

/// The full history window's chrome (#164): Settings' — the system titlebar, see-through
/// over the window's `surface`, and the theme's appearance, so the titlebar, menus and the
/// Clear history alert match the palette — and the size the tokens give it.
///
/// Lives in ThemeKit rather than in the app so a test can build a window, configure it,
/// switch the theme and read back what the window took.
@MainActor
public enum ThemedFullHistoryWindow {
    /// The chrome, the content size and its minimum, and the current colours. Called once,
    /// before the window is placed.
    public static func configure(_ window: NSWindow, tokens: ThemeTokens) {
        window.titlebarAppearsTransparent = true
        window.setContentSize(tokens.fullHistory.contentSize)
        window.contentMinSize = tokens.fullHistory.minContentSize
        applyTheme(tokens, to: window)
    }

    /// The theme's colours and appearance. Nothing else: the themes differ only in
    /// colours, so a switch moves and resizes nothing.
    public static func applyTheme(_ tokens: ThemeTokens, to window: NSWindow) {
        window.backgroundColor = tokens.colors.surface.nsColor
        window.appearance = tokens.windowAppearance.nsAppearance
    }

    /// Re-applies the theme on every switch while the window is open. Keep the returned
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
