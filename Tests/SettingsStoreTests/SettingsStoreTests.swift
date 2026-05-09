import XCTest
@testable import SettingsStore
import HotkeyEngine
import KeychainStore
import TranscriptionProvider

@MainActor
final class SettingsStoreTests: XCTestCase {
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

    func testDefaultsWhenEmpty() {
        let keychain = InMemoryKeychain()
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(store.provider, .openai)
        XCTAssertEqual(store.openAIModel, .whisper1)
        XCTAssertEqual(store.language, .auto)
        XCTAssertEqual(store.triggerKey, .rightOption)
        XCTAssertEqual(store.triggerMode, .tap)
        XCTAssertEqual(store.hotkeyConfig, HotkeyConfig(trigger: .rightOption, mode: .tap))
        XCTAssertTrue(store.soundEffectsEnabled)
        XCTAssertEqual(store.openAIAPIKey, "")
    }

    func testValuesPersistAcrossInstances() {
        let keychain = InMemoryKeychain()
        let first = SettingsStore(keychain: keychain, defaults: defaults)
        first.openAIModel = .gpt4oMiniTranscribe
        first.language = .russian
        first.triggerKey = .rightShift
        first.triggerMode = .hold
        first.soundEffectsEnabled = false
        first.openAIAPIKey = "sk-persisted"

        let second = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(second.openAIModel, .gpt4oMiniTranscribe)
        XCTAssertEqual(second.language, .russian)
        XCTAssertEqual(second.triggerKey, .rightShift)
        XCTAssertEqual(second.triggerMode, .hold)
        XCTAssertEqual(second.hotkeyConfig, HotkeyConfig(trigger: .rightShift, mode: .hold))
        XCTAssertFalse(second.soundEffectsEnabled)
        XCTAssertEqual(second.openAIAPIKey, "sk-persisted")
    }

    func testClearingAPIKeyRemovesKeychainEntry() throws {
        let keychain = InMemoryKeychain()
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        store.openAIAPIKey = "sk-temp"
        XCTAssertEqual(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            ),
            "sk-temp"
        )
        store.openAIAPIKey = ""
        XCTAssertNil(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            )
        )
    }

    func testLegacyKeychainEntryMigrates() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("sk-legacy", service: "WhisperKey", account: "OPENAI_API_KEY")

        let store = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(store.openAIAPIKey, "sk-legacy")
        XCTAssertEqual(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            ),
            "sk-legacy"
        )
    }

    func testNewFormatTakesPrecedenceOverLegacy() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("sk-legacy", service: "WhisperKey", account: "OPENAI_API_KEY")
        try keychain.write(
            "sk-new",
            service: TranscriptionProviderID.openai.keychainService,
            account: TranscriptionProviderID.openai.keychainAccount
        )

        let store = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(store.openAIAPIKey, "sk-new")
    }

    func testMakeProviderReturnsNilWhenKeyEmpty() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertNil(store.makeTranscriptionProvider())
    }

    func testMakeProviderReturnsOpenAIWhenKeyPresent() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.openAIAPIKey = "sk-x"
        store.openAIModel = .gpt4oMiniTranscribe

        guard let provider = store.makeTranscriptionProvider() as? OpenAIProvider else {
            XCTFail("expected OpenAIProvider")
            return
        }
        XCTAssertEqual(provider.apiKey, "sk-x")
        XCTAssertEqual(provider.model, .gpt4oMiniTranscribe)
    }
}

final class TranscriptionLanguageTests: XCTestCase {
    func testAutoMapsToNilISO() {
        XCTAssertNil(TranscriptionLanguage.auto.isoCode)
    }

    func testEnglishMapsToEN() {
        XCTAssertEqual(TranscriptionLanguage.english.isoCode, "en")
    }

    func testRussianMapsToRU() {
        XCTAssertEqual(TranscriptionLanguage.russian.isoCode, "ru")
    }

    func testAllCasesHaveDisplayName() {
        for language in TranscriptionLanguage.allCases {
            XCTAssertFalse(language.displayName.isEmpty)
        }
    }
}
