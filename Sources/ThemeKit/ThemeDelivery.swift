import AppKit
import Combine
import os
import SettingsStore
import SwiftUI

/// The tokens of the theme chosen in Settings, kept current as the choice changes and,
/// under Auto, as the system switches between light and dark.
///
/// One instance, `shared`, serves the whole app, because several surfaces are built far
/// from any `SettingsStore` (the toast, the quick paste popup, the reader, Reset usage).
/// Every hosting root that has the app's store at hand calls `follow(_:)` before it
/// builds its view; the call is idempotent, so whichever root comes first connects it.
/// The roots without a store read `shared` and are always built after one that has it.
@MainActor
public final class ThemeTokensSource: ObservableObject {
    public static let shared = ThemeTokensSource()

    @Published public private(set) var tokens: ThemeTokens

    private weak var followed: SettingsStore?
    private var subscription: AnyCancellable?
    private let systemIsDark: () -> AnyPublisher<Bool, Never>

    /// Starts at `theme` and stays there until it follows a store. `systemIsDark`
    /// reports the system's appearance, now and on every change; by default it reads the
    /// app's effective appearance, which follows the system because the app never sets
    /// its own. It is subscribed only when a store is followed.
    public init(
        theme: AppTheme = .daylight,
        systemIsDark: (() -> AnyPublisher<Bool, Never>)? = nil
    ) {
        tokens = theme.tokens
        self.systemIsDark = systemIsDark ?? Self.applicationIsDark
    }

    /// Takes the store's theme now and every time it changes. Following the store
    /// already followed does nothing; following another one replaces it.
    public func follow(_ settings: SettingsStore) {
        guard followed !== settings else { return }
        followed = settings
        subscription = settings.$theme
            .combineLatest(systemIsDark().removeDuplicates())
            .map { choice, isDark in choice.resolved(systemIsDark: isDark) }
            .removeDuplicates()
            .sink { [weak self] theme in
                self?.tokens = theme.tokens
            }
    }

    private static func applicationIsDark() -> AnyPublisher<Bool, Never> {
        NSApplication.shared
            .publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .map { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
            .eraseToAnyPublisher()
    }
}

private struct ThemeTokensKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.daylight
}

public extension EnvironmentValues {
    /// The current theme's tokens. Every hosting root sets it through `ThemedRoot`;
    /// a view outside one sees Daylight's tokens.
    var themeTokens: ThemeTokens {
        get { self[ThemeTokensKey.self] }
        set { self[ThemeTokensKey.self] = newValue }
    }
}

/// The root of every `NSHostingView` / `NSHostingController` in the app: hands its
/// content the current tokens through the environment and redraws it when they change,
/// so an open window follows a theme switch without being reopened.
public struct ThemedRoot<Content: View>: View {
    @ObservedObject private var source: ThemeTokensSource
    private let name: String
    private let content: Content

    /// Reads `ThemeTokensSource.shared`. `name` identifies the root in the Debug
    /// build's delivery log.
    @MainActor
    public init(_ name: String, @ViewBuilder content: () -> Content) {
        self.init(name, source: .shared, content: content)
    }

    public init(_ name: String, source: ThemeTokensSource, @ViewBuilder content: () -> Content) {
        self.name = name
        self.source = source
        self.content = content()
    }

    public var body: some View {
        content
            #if DEBUG
            .background(ThemeDeliveryProbe(root: name))
            #endif
            .environment(\.themeTokens, source.tokens)
    }
}

#if DEBUG
/// Logs which theme's tokens reached a root, read back from the environment the way any
/// view of that root reads them. It draws nothing. It is how the delivery is checked on
/// the installed dev app while no view uses the tokens yet:
/// `/usr/bin/log show --last 5m --predicate 'subsystem == "WhisperKey" AND category == "ThemeTokens"'`.
private struct ThemeDeliveryProbe: View {
    private static let log = Logger(subsystem: "WhisperKey", category: "ThemeTokens")

    let root: String
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        Color.clear
            .onAppear {
                Self.log.info("tokens delivered root=\(root, privacy: .public) theme=\(tokens.theme.rawValue, privacy: .public) on=appear")
            }
            .onChange(of: tokens.theme) { _, theme in
                Self.log.info("tokens delivered root=\(root, privacy: .public) theme=\(theme.rawValue, privacy: .public) on=change")
            }
    }
}
#endif
