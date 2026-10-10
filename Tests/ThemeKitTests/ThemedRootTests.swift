import AppKit
import KeychainStore
import SettingsStore
import SwiftUI
import XCTest
@testable import ThemeKit

/// `ThemedRoot` hosted the way the app hosts it, in an `NSHostingView`, with a view
/// inside that reads `\.themeTokens` as any surface will.
@MainActor
final class ThemedRootTests: XCTestCase {
    private final class Seen {
        var themes: [AppTheme] = []
    }

    private struct Reader: View {
        let seen: Seen
        @Environment(\.themeTokens) private var tokens

        var body: some View {
            seen.themes.append(tokens.theme)
            return Text(tokens.theme.rawValue)
        }
    }

    private func render(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
    }

    func testTheContentReadsTheSourcesTokens() {
        let seen = Seen()
        let host = NSHostingView(rootView: ThemedRoot("test", source: ThemeTokensSource(theme: .midnight)) {
            Reader(seen: seen)
        })
        render(host)
        XCTAssertEqual(seen.themes.last, .midnight)
    }

    /// The acceptance's "an already-open window follows the switch": the same hosting
    /// view, never rebuilt, redraws its content with the new tokens.
    func testAnOpenRootFollowsAThemeSwitch() {
        let suite = "WhisperKey.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.theme = .classic
        let source = ThemeTokensSource()
        source.follow(store)

        let seen = Seen()
        let host = NSHostingView(rootView: ThemedRoot("test", source: source) {
            Reader(seen: seen)
        })
        render(host)
        XCTAssertEqual(seen.themes.last, .classic)

        store.theme = .midnight
        render(host)
        XCTAssertEqual(seen.themes.last, .midnight)

        store.theme = .classic
        render(host)
        XCTAssertEqual(seen.themes.last, .classic)
    }
}
