import KeychainStore
import SettingsStore
import XCTest
@testable import ThemeKit

@MainActor
final class ThemeTokensSourceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WhisperKey.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(theme: AppTheme) -> SettingsStore {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.theme = theme
        return store
    }

    func testStartsInClassicUntilItFollowsAStore() {
        XCTAssertEqual(ThemeTokensSource().tokens, .classic)
    }

    func testTakesTheStoresThemeAtOnce() {
        let source = ThemeTokensSource()
        source.follow(makeStore(theme: .midnight))
        XCTAssertEqual(source.tokens, .midnight)
    }

    /// The live update: a theme switched in Settings reaches an already-built root.
    func testFollowsEveryThemeChange() {
        let store = makeStore(theme: .classic)
        let source = ThemeTokensSource()
        source.follow(store)
        var published: [AppTheme] = []
        let subscription = source.$tokens.dropFirst().sink { published.append($0.theme) }

        store.theme = .midnight
        XCTAssertEqual(source.tokens, .midnight)
        store.theme = .classic
        XCTAssertEqual(source.tokens, .classic)
        XCTAssertEqual(published, [.midnight, .classic])
        subscription.cancel()
    }

    /// Several roots follow the same store; the source must not republish per root.
    func testFollowingTheSameStoreAgainChangesNothing() {
        let store = makeStore(theme: .classic)
        let source = ThemeTokensSource()
        source.follow(store)
        var published = 0
        let subscription = source.$tokens.dropFirst().sink { _ in published += 1 }

        source.follow(store)
        source.follow(store)
        XCTAssertEqual(published, 0)
        store.theme = .midnight
        XCTAssertEqual(published, 1)
        subscription.cancel()
    }

    func testSettingTheSameThemeAgainDoesNotRepublish() {
        let store = makeStore(theme: .midnight)
        let source = ThemeTokensSource()
        source.follow(store)
        var published = 0
        let subscription = source.$tokens.dropFirst().sink { _ in published += 1 }

        store.theme = .midnight
        XCTAssertEqual(published, 0)
        subscription.cancel()
    }

    func testFollowingAnotherStoreLeavesTheFirst() {
        let first = makeStore(theme: .classic)
        let second = makeStore(theme: .midnight)
        let source = ThemeTokensSource()
        source.follow(first)
        source.follow(second)
        XCTAssertEqual(source.tokens, .midnight)

        first.theme = .midnight
        first.theme = .classic
        XCTAssertEqual(source.tokens, .midnight, "the first store no longer drives it")
    }
}
