import Combine
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

    private func makeStore(theme: ThemeChoice) -> SettingsStore {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.theme = theme
        return store
    }

    func testStartsInDaylightUntilItFollowsAStore() {
        XCTAssertEqual(ThemeTokensSource().tokens, .daylight)
    }

    func testTakesTheStoresThemeAtOnce() {
        let source = ThemeTokensSource()
        source.follow(makeStore(theme: .midnight))
        XCTAssertEqual(source.tokens, .midnight)
    }

    /// The live update: a theme switched in Settings reaches an already-built root.
    func testFollowsEveryThemeChange() {
        let store = makeStore(theme: .daylight)
        let source = ThemeTokensSource()
        source.follow(store)
        var published: [AppTheme] = []
        let subscription = source.$tokens.dropFirst().sink { published.append($0.theme) }

        store.theme = .midnight
        XCTAssertEqual(source.tokens, .midnight)
        store.theme = .daylight
        XCTAssertEqual(source.tokens, .daylight)
        XCTAssertEqual(published, [.midnight, .daylight])
        subscription.cancel()
    }

    /// Several roots follow the same store; the source must not republish per root.
    func testFollowingTheSameStoreAgainChangesNothing() {
        let store = makeStore(theme: .daylight)
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
        let first = makeStore(theme: .daylight)
        let second = makeStore(theme: .midnight)
        let source = ThemeTokensSource()
        source.follow(first)
        source.follow(second)
        XCTAssertEqual(source.tokens, .midnight)

        first.theme = .midnight
        first.theme = .daylight
        XCTAssertEqual(source.tokens, .midnight, "the first store no longer drives it")
    }

    // MARK: Auto

    private func makeSource(system: CurrentValueSubject<Bool, Never>) -> ThemeTokensSource {
        ThemeTokensSource(systemIsDark: { system.eraseToAnyPublisher() })
    }

    func testAutoDrawsTheSystemsAppearance() {
        let dark = CurrentValueSubject<Bool, Never>(true)
        let darkSource = makeSource(system: dark)
        darkSource.follow(makeStore(theme: .auto))
        XCTAssertEqual(darkSource.tokens, .midnight)

        let light = CurrentValueSubject<Bool, Never>(false)
        let lightSource = makeSource(system: light)
        lightSource.follow(makeStore(theme: .auto))
        XCTAssertEqual(lightSource.tokens, .daylight)
    }

    /// The system switching while windows are open repaints them, without a Settings change.
    func testAutoFollowsTheSystemSwitchingLive() {
        let system = CurrentValueSubject<Bool, Never>(false)
        let source = makeSource(system: system)
        source.follow(makeStore(theme: .auto))
        var published: [AppTheme] = []
        let subscription = source.$tokens.dropFirst().sink { published.append($0.theme) }

        system.send(true)
        XCTAssertEqual(source.tokens, .midnight)
        system.send(true)
        system.send(false)
        XCTAssertEqual(source.tokens, .daylight)
        XCTAssertEqual(published, [.midnight, .daylight], "a repeated value does not republish")
        subscription.cancel()
    }

    func testAFixedThemeIgnoresTheSystem() {
        let system = CurrentValueSubject<Bool, Never>(true)
        let source = makeSource(system: system)
        source.follow(makeStore(theme: .daylight))
        XCTAssertEqual(source.tokens, .daylight)
        system.send(false)
        system.send(true)
        XCTAssertEqual(source.tokens, .daylight)
    }

    /// Picking Auto when it resolves to the theme already drawn changes nothing on screen.
    func testSwitchingToAutoOnTheSameAppearanceDoesNotRepublish() {
        let system = CurrentValueSubject<Bool, Never>(true)
        let store = makeStore(theme: .midnight)
        let source = makeSource(system: system)
        source.follow(store)
        var published = 0
        let subscription = source.$tokens.dropFirst().sink { _ in published += 1 }

        store.theme = .auto
        XCTAssertEqual(published, 0)
        XCTAssertEqual(source.tokens, .midnight)
        subscription.cancel()
    }
}
