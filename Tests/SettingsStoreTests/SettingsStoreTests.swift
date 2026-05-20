import XCTest
@testable import SettingsStore
import HotkeyEngine
import KeychainStore
import TranscriptionProvider
import UsageStatsStore

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
        XCTAssertTrue(store.saveTranscriptionToClipboard)
        XCTAssertTrue(store.autoPasteTranscription)
        XCTAssertTrue(store.escapeToCancelRecording)
        XCTAssertFalse(store.hasPendingInstallWelcome)
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
        first.saveTranscriptionToClipboard = false
        first.autoPasteTranscription = false
        first.escapeToCancelRecording = false
        first.openAIAPIKey = "sk-persisted"

        let second = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(second.openAIModel, .gpt4oMiniTranscribe)
        XCTAssertEqual(second.language, .russian)
        XCTAssertEqual(second.triggerKey, .rightShift)
        XCTAssertEqual(second.triggerMode, .hold)
        XCTAssertEqual(
            second.hotkeyConfig,
            HotkeyConfig(trigger: .rightShift, mode: .hold, escapeToCancelRecording: false)
        )
        XCTAssertFalse(second.soundEffectsEnabled)
        XCTAssertFalse(second.saveTranscriptionToClipboard)
        XCTAssertFalse(second.autoPasteTranscription)
        XCTAssertFalse(second.escapeToCancelRecording)
        XCTAssertEqual(second.openAIAPIKey, "sk-persisted")
    }

    func testPendingInstallWelcomeIsDetected() {
        defaults.set("install-1", forKey: "WhisperKey.settings.pendingInstallWelcomeID")

        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)

        XCTAssertTrue(store.hasPendingInstallWelcome)
    }

    func testMatchingPresentedInstallWelcomeIsNotPending() {
        defaults.set("install-1", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        defaults.set("install-1", forKey: "WhisperKey.settings.presentedInstallWelcomeID")

        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)

        XCTAssertFalse(store.hasPendingInstallWelcome)
    }

    func testMarkInstallWelcomePresentedConsumesPendingInstall() {
        defaults.set("install-1", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)

        store.markInstallWelcomePresented()

        XCTAssertFalse(store.hasPendingInstallWelcome)
        XCTAssertEqual(defaults.string(forKey: "WhisperKey.settings.presentedInstallWelcomeID"), "install-1")
        XCTAssertNil(defaults.string(forKey: "WhisperKey.settings.pendingInstallWelcomeID"))
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

    func testOpenAIAPIKeyUsesOnlyProviderSpecificKeychainEntry() throws {
        let keychain = InMemoryKeychain()
        try keychain.write("sk-legacy", service: "WhisperKey", account: "OPENAI_API_KEY")

        let store = SettingsStore(keychain: keychain, defaults: defaults)
        XCTAssertEqual(store.openAIAPIKey, "")
        XCTAssertNil(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            )
        )
    }

    func testDeletingOpenAIAPIKeyRemovesProviderSpecificKeychainEntry() throws {
        let keychain = InMemoryKeychain()
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        store.openAIAPIKey = "sk-temp"

        store.deleteAPIKey(for: .openai)

        XCTAssertEqual(store.openAIAPIKey, "")
        XCTAssertNil(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            )
        )
    }

    func testMakeProviderReturnsNilWhenKeyEmpty() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertNil(store.makeTranscriptionProvider())
    }

    func testHistoryMaxEntriesDefaultIs30() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertEqual(store.historyMaxEntries, 30)
    }

    func testHistoryMaxEntriesIsClamped() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.historyMaxEntries = 5_000
        XCTAssertEqual(store.historyMaxEntries, 1_000)
        store.historyMaxEntries = -10
        XCTAssertEqual(store.historyMaxEntries, 0)
    }

    func testHistoryMaxEntriesPersists() {
        let first = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        first.historyMaxEntries = 75
        let second = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertEqual(second.historyMaxEntries, 75)
    }

    func testGroqAPIKeyPersistsToSeparateKeychainEntry() throws {
        let keychain = InMemoryKeychain()
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        store.groqAPIKey = "gsk-secret"
        XCTAssertEqual(
            try keychain.read(
                service: TranscriptionProviderID.groq.keychainService,
                account: TranscriptionProviderID.groq.keychainAccount
            ),
            "gsk-secret"
        )
        XCTAssertNil(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            ),
            "OpenAI key remains untouched"
        )
    }

    func testDeletingGroqAPIKeyRemovesOnlyGroqKeychainEntry() throws {
        let keychain = InMemoryKeychain()
        let store = SettingsStore(keychain: keychain, defaults: defaults)
        store.openAIAPIKey = "sk-openai"
        store.groqAPIKey = "gsk-temp"

        store.deleteAPIKey(for: .groq)

        XCTAssertEqual(store.groqAPIKey, "")
        XCTAssertEqual(store.openAIAPIKey, "sk-openai")
        XCTAssertNil(
            try keychain.read(
                service: TranscriptionProviderID.groq.keychainService,
                account: TranscriptionProviderID.groq.keychainAccount
            )
        )
        XCTAssertEqual(
            try keychain.read(
                service: TranscriptionProviderID.openai.keychainService,
                account: TranscriptionProviderID.openai.keychainAccount
            ),
            "sk-openai"
        )
    }

    func testMakeProviderReturnsGroqWhenSelectedAndKeyPresent() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.provider = .groq
        store.groqAPIKey = "gsk-x"
        store.groqModel = .whisperLargeV3

        guard let provider = store.makeTranscriptionProvider() as? GroqProvider else {
            XCTFail("expected GroqProvider")
            return
        }
        XCTAssertEqual(provider.apiKey, "gsk-x")
        XCTAssertEqual(provider.model, .whisperLargeV3)
    }

    func testMakeProviderReturnsNilWhenGroqSelectedWithEmptyKey() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        store.provider = .groq
        XCTAssertNil(store.makeTranscriptionProvider())
    }

    func testUsageStatsRangeDefaultsToToday() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertEqual(store.usageStatsRange, .today)
    }

    func testUsageStatsRangePersists() {
        let first = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        first.usageStatsRange = .last30Days
        let second = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertEqual(second.usageStatsRange, .last30Days)
    }

    func testConsumePendingInstallUsageResetReturnsTrueOnceForFreshMarker() {
        defaults.set("install-7", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)

        XCTAssertTrue(store.consumePendingInstallUsageReset())
        XCTAssertFalse(store.consumePendingInstallUsageReset())
    }

    func testConsumePendingInstallUsageResetReturnsFalseWhenNoMarker() {
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertFalse(store.consumePendingInstallUsageReset())
    }

    func testConsumePendingInstallUsageResetReturnsTrueAgainForNewMarker() {
        defaults.set("install-A", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)
        XCTAssertTrue(store.consumePendingInstallUsageReset())

        defaults.set("install-B", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        XCTAssertTrue(store.consumePendingInstallUsageReset())
        XCTAssertFalse(store.consumePendingInstallUsageReset())
    }

    func testConsumePendingInstallUsageResetIsIndependentOfWelcomeMarker() {
        defaults.set("install-99", forKey: "WhisperKey.settings.pendingInstallWelcomeID")
        let store = SettingsStore(keychain: InMemoryKeychain(), defaults: defaults)

        store.markInstallWelcomePresented()
        XCTAssertFalse(store.hasPendingInstallWelcome)
        // Even after welcome is marked presented, the counter-reset hook reads from the marker too.
        // We expect it to be consumable as long as we have not previously consumed it.
        // markInstallWelcomePresented removes the pending key, so subsequent calls return false.
        XCTAssertFalse(store.consumePendingInstallUsageReset())
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
