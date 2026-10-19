import Foundation
import Combine
import HotkeyEngine
import KeychainStore
import QuickPaste
import TranscriptionProvider
import UsageStatsStore

public enum TranscriptionLanguage: String, CaseIterable, Codable, Sendable {
    case auto
    case english
    case russian

    public var isoCode: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .russian: return "ru"
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .russian: return "Russian"
        }
    }
}

public enum TranscriptionProviderID: String, CaseIterable, Codable, Sendable {
    case openai
    case groq

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq Whisper"
        }
    }

    /// Compact provider name for tight places such as the popover header.
    public var shortDisplayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    public var keychainService: String { "WhisperKey.\(rawValue)" }
    public var keychainAccount: String { "apiKey" }
}

/// The app's look, chosen in General settings: Daylight (light) or Midnight (dark), one
/// layout in two palettes. A third theme is a new case here.
public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    /// Stored as "classic", the theme's name before it became Daylight, so the setting
    /// of existing users still resolves.
    case daylight = "classic"
    case midnight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .daylight: return "Daylight"
        case .midnight: return "Midnight"
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    private enum DefaultsKey {
        static let provider = "WhisperKey.settings.provider"
        static let openAIModel = "WhisperKey.settings.openAIModel"
        static let groqModel = "WhisperKey.settings.groqModel"
        static let language = "WhisperKey.settings.language"
        static let triggerKey = "WhisperKey.settings.triggerKey"
        static let triggerMode = "WhisperKey.settings.triggerMode"
        static let soundEffectsEnabled = "WhisperKey.settings.soundEffectsEnabled"
        static let historyMaxEntries = "WhisperKey.settings.historyMaxEntries"
        static let saveTranscriptionToClipboard = "WhisperKey.settings.saveTranscriptionToClipboard"
        static let autoPasteTranscription = "WhisperKey.settings.autoPasteTranscription"
        static let escapeToCancelRecording = "WhisperKey.settings.escapeToCancelRecording"
        static let pauseMediaWhileRecording = "WhisperKey.settings.pauseAppleMusicWhileRecording"
        static let pendingInstallWelcomeID = "WhisperKey.settings.pendingInstallWelcomeID"
        static let presentedInstallWelcomeID = "WhisperKey.settings.presentedInstallWelcomeID"
        static let usageStatsRange = "WhisperKey.settings.usageStatsRange"
        static let theme = "WhisperKey.settings.theme"
        // The enabled key is the one #79 wrote by hand as a hidden flag, kept so anyone
        // who turned it on that way keeps the feature on.
        static let quickPasteEnabled = "WhisperKey.settings.quickPasteEnabled"
        static let quickPasteTriggerKey = "WhisperKey.settings.quickPasteTriggerKey"
        static let quickPasteHoldDuration = "WhisperKey.settings.quickPasteHoldDuration"
        static let quickPasteEntryCount = "WhisperKey.settings.quickPasteEntryCount"

        /// When the provider last refused the stored key, as a plist `Date`. Absent when
        /// the key has not been refused since it was saved.
        static func apiKeyRejectedAt(_ id: TranscriptionProviderID) -> String {
            "WhisperKey.settings.apiKeyRejectedAt.\(id.rawValue)"
        }
    }

    /// What the one launch-time check of the stored key found.
    public enum LaunchAPIKeyCheckOutcome: Sendable, Equatable {
        /// No key stored for the selected provider, or it changed while the check ran.
        case skipped
        case accepted
        /// The provider refused the key: it is now marked rejected.
        case rejected
        /// No answer about the key (no network, timeout, rate limit, server error).
        case unavailable
    }

    public typealias APIKeyValidator = @Sendable (TranscriptionProviderID, String) async -> APIKeyValidationResult

    public static let defaultHistoryMaxEntries = 30
    public static let historyMaxEntriesRange: ClosedRange<Int> = 0...1000

    public static let defaultQuickPasteTriggerKey = QuickPasteConfiguration.defaultTrigger
    public static let defaultQuickPasteHoldDuration = QuickPasteConfiguration.defaultHoldDuration
    /// Below 200 ms the popup starts appearing during ordinary chords; above two seconds
    /// nobody would wait for it.
    public static let quickPasteHoldDurationRange: ClosedRange<TimeInterval> = 0.2...2.0
    public static let defaultQuickPasteEntryCount = QuickPasteConfiguration.defaultVisibleEntryCount
    public static let quickPasteEntryCountRange: ClosedRange<Int> = 1...10

    private let keychain: KeychainStorage
    private let defaults: UserDefaults
    private let installMarkerDefaults: UserDefaults?
    private var loading = true
    /// Reads the API keys off the main thread. A Keychain access prompt holds the read
    /// for as long as the user leaves it unanswered, and the app has to reach the menu
    /// bar meanwhile.
    private var apiKeyLoad: Task<Void, Never>?
    /// Keys the user set or deleted before that read finished. The read's older value
    /// must not overwrite them.
    private var editedAPIKeys: Set<TranscriptionProviderID> = []

    @Published public var provider: TranscriptionProviderID {
        didSet { if !loading { defaults.set(provider.rawValue, forKey: DefaultsKey.provider) } }
    }

    @Published public var openAIModel: OpenAIProvider.Model {
        didSet { if !loading { defaults.set(openAIModel.rawValue, forKey: DefaultsKey.openAIModel) } }
    }

    @Published public var groqModel: GroqProvider.Model {
        didSet { if !loading { defaults.set(groqModel.rawValue, forKey: DefaultsKey.groqModel) } }
    }

    @Published public var language: TranscriptionLanguage {
        didSet { if !loading { defaults.set(language.rawValue, forKey: DefaultsKey.language) } }
    }

    /// The recording trigger.
    ///
    /// Validated against the quick-paste trigger in the same re-entrant `didSet` shape
    /// `historyMaxEntries` uses: an unacceptable value puts the old one straight back, so
    /// the rejection is visible in the property itself rather than in whoever set it.
    /// This is the direction that is easy to forget — moving *recording* onto the key the
    /// popup already holds is as much a collision as the other way round.
    @Published public var triggerKey: TriggerKey {
        didSet {
            if triggerKey == quickPasteTriggerKey {
                triggerKey = oldValue
                return
            }
            if !loading { defaults.set(triggerKey.rawValue, forKey: DefaultsKey.triggerKey) }
        }
    }

    @Published public var triggerMode: TriggerMode {
        didSet { if !loading { defaults.set(triggerMode.rawValue, forKey: DefaultsKey.triggerMode) } }
    }

    @Published public var soundEffectsEnabled: Bool {
        didSet { if !loading { defaults.set(soundEffectsEnabled, forKey: DefaultsKey.soundEffectsEnabled) } }
    }

    @Published public var saveTranscriptionToClipboard: Bool {
        didSet {
            if !loading {
                defaults.set(saveTranscriptionToClipboard, forKey: DefaultsKey.saveTranscriptionToClipboard)
            }
        }
    }

    @Published public var autoPasteTranscription: Bool {
        didSet {
            if !loading {
                defaults.set(autoPasteTranscription, forKey: DefaultsKey.autoPasteTranscription)
            }
        }
    }

    @Published public var escapeToCancelRecording: Bool {
        didSet {
            if !loading {
                defaults.set(escapeToCancelRecording, forKey: DefaultsKey.escapeToCancelRecording)
            }
        }
    }

    @Published public var pauseMediaWhileRecording: Bool {
        didSet {
            if !loading {
                defaults.set(pauseMediaWhileRecording, forKey: DefaultsKey.pauseMediaWhileRecording)
            }
        }
    }

    @Published public var usageStatsRange: UsageStatsRange {
        didSet {
            if !loading {
                defaults.set(usageStatsRange.rawValue, forKey: DefaultsKey.usageStatsRange)
            }
        }
    }

    @Published public var theme: AppTheme {
        didSet { if !loading { defaults.set(theme.rawValue, forKey: DefaultsKey.theme) } }
    }

    /// The whole quick-paste popup, behind one switch. Default off.
    @Published public var quickPasteEnabled: Bool {
        didSet {
            if !loading { defaults.set(quickPasteEnabled, forKey: DefaultsKey.quickPasteEnabled) }
        }
    }

    /// The key that opens the popup. Rejects the key recording holds — the other half of
    /// the validation on `triggerKey`.
    @Published public var quickPasteTriggerKey: TriggerKey {
        didSet {
            if quickPasteTriggerKey == triggerKey {
                quickPasteTriggerKey = oldValue
                return
            }
            if !loading {
                defaults.set(quickPasteTriggerKey.rawValue, forKey: DefaultsKey.quickPasteTriggerKey)
            }
        }
    }

    /// How long the trigger has to be held before the popup appears, in seconds.
    @Published public var quickPasteHoldDuration: TimeInterval {
        didSet {
            let clamped = Self.clampQuickPasteHoldDuration(quickPasteHoldDuration)
            if clamped != quickPasteHoldDuration {
                quickPasteHoldDuration = clamped
                return
            }
            if !loading {
                defaults.set(quickPasteHoldDuration, forKey: DefaultsKey.quickPasteHoldDuration)
            }
        }
    }

    /// How many clipboard entries the popup lists.
    @Published public var quickPasteEntryCount: Int {
        didSet {
            let clamped = Self.clampQuickPasteEntryCount(quickPasteEntryCount)
            if clamped != quickPasteEntryCount {
                quickPasteEntryCount = clamped
                return
            }
            if !loading {
                defaults.set(quickPasteEntryCount, forKey: DefaultsKey.quickPasteEntryCount)
            }
        }
    }

    @Published public var historyMaxEntries: Int {
        didSet {
            let clamped = Self.clampHistoryMax(historyMaxEntries)
            if clamped != historyMaxEntries {
                historyMaxEntries = clamped
                return
            }
            if !loading { defaults.set(historyMaxEntries, forKey: DefaultsKey.historyMaxEntries) }
        }
    }

    /// Empty until the background Keychain read finishes; a key still loading is a
    /// missing key.
    @Published public var openAIAPIKey: String {
        didSet {
            if !loading {
                editedAPIKeys.insert(.openai)
                persistAPIKey(openAIAPIKey, for: .openai)
                setAPIKeyRejectedAt(nil, for: .openai)
            }
        }
    }

    @Published public var groqAPIKey: String {
        didSet {
            if !loading {
                editedAPIKeys.insert(.groq)
                persistAPIKey(groqAPIKey, for: .groq)
                setAPIKeyRejectedAt(nil, for: .groq)
            }
        }
    }

    /// When each provider refused its stored key. A key in here is stored but known not
    /// to work, so Settings must not present it as configured.
    @Published public private(set) var apiKeyRejections: [TranscriptionProviderID: Date] = [:]

    public init(keychain: KeychainStorage = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        self.installMarkerDefaults = defaults === UserDefaults.standard
            ? UserDefaults(suiteName: "yung-sun-xxi.WhisperKey")
            : nil

        // Pull in install markers written by the installer before loading cached preferences.
        defaults.synchronize()
        installMarkerDefaults?.synchronize()

        self.provider = (defaults.string(forKey: DefaultsKey.provider).flatMap(TranscriptionProviderID.init(rawValue:))) ?? .openai
        self.openAIModel = (defaults.string(forKey: DefaultsKey.openAIModel).flatMap(OpenAIProvider.Model.init(rawValue:))) ?? .gptTranscribe
        self.groqModel = (defaults.string(forKey: DefaultsKey.groqModel).flatMap(GroqProvider.Model.init(rawValue:))) ?? .whisperLargeV3Turbo
        self.language = (defaults.string(forKey: DefaultsKey.language).flatMap(TranscriptionLanguage.init(rawValue:))) ?? .auto
        let recordingTrigger = (defaults.string(forKey: DefaultsKey.triggerKey).flatMap(TriggerKey.init(rawValue:))) ?? .rightOption
        self.triggerKey = recordingTrigger
        // A stored pair can only collide if it was written before this validation
        // existed. Recording keeps its key and the popup moves to a free one, so the app
        // never comes up in a configuration it would refuse to be put into by hand.
        let storedQuickPasteTrigger = (defaults.string(forKey: DefaultsKey.quickPasteTriggerKey)
            .flatMap(TriggerKey.init(rawValue:))) ?? Self.defaultQuickPasteTriggerKey
        self.quickPasteTriggerKey = Self.resolveQuickPasteTrigger(
            storedQuickPasteTrigger,
            recordingTrigger: recordingTrigger
        )
        self.triggerMode = (defaults.string(forKey: DefaultsKey.triggerMode).flatMap(TriggerMode.init(rawValue:))) ?? .tap
        self.soundEffectsEnabled = (defaults.object(forKey: DefaultsKey.soundEffectsEnabled) as? Bool) ?? true
        self.saveTranscriptionToClipboard = (defaults.object(forKey: DefaultsKey.saveTranscriptionToClipboard) as? Bool) ?? true
        self.autoPasteTranscription = (defaults.object(forKey: DefaultsKey.autoPasteTranscription) as? Bool) ?? true
        self.escapeToCancelRecording = (defaults.object(forKey: DefaultsKey.escapeToCancelRecording) as? Bool) ?? true
        self.pauseMediaWhileRecording = (defaults.object(forKey: DefaultsKey.pauseMediaWhileRecording) as? Bool) ?? true
        let storedHistoryMax = (defaults.object(forKey: DefaultsKey.historyMaxEntries) as? Int) ?? Self.defaultHistoryMaxEntries
        self.historyMaxEntries = Self.clampHistoryMax(storedHistoryMax)
        self.usageStatsRange = (defaults.string(forKey: DefaultsKey.usageStatsRange).flatMap(UsageStatsRange.init(rawValue:))) ?? .today
        // Missing or unknown (a theme removed in a later version) falls back to Daylight.
        self.theme = (defaults.string(forKey: DefaultsKey.theme).flatMap(AppTheme.init(rawValue:))) ?? .daylight
        self.quickPasteEnabled = (defaults.object(forKey: DefaultsKey.quickPasteEnabled) as? Bool) ?? false
        let storedHoldDuration = (defaults.object(forKey: DefaultsKey.quickPasteHoldDuration) as? Double)
            ?? Self.defaultQuickPasteHoldDuration
        self.quickPasteHoldDuration = Self.clampQuickPasteHoldDuration(storedHoldDuration)
        let storedEntryCount = (defaults.object(forKey: DefaultsKey.quickPasteEntryCount) as? Int)
            ?? Self.defaultQuickPasteEntryCount
        self.quickPasteEntryCount = Self.clampQuickPasteEntryCount(storedEntryCount)
        self.openAIAPIKey = ""
        self.groqAPIKey = ""
        var rejections: [TranscriptionProviderID: Date] = [:]
        for id in TranscriptionProviderID.allCases {
            rejections[id] = defaults.object(forKey: DefaultsKey.apiKeyRejectedAt(id)) as? Date
        }
        self.apiKeyRejections = rejections

        self.loading = false

        apiKeyLoad = Task { @MainActor [weak self, keychain] in
            let keys = await Self.readAPIKeys(from: keychain)
            self?.applyLoadedAPIKeys(keys)
        }
    }

    private static func clampHistoryMax(_ value: Int) -> Int {
        min(max(value, historyMaxEntriesRange.lowerBound), historyMaxEntriesRange.upperBound)
    }

    private static func clampQuickPasteHoldDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value, quickPasteHoldDurationRange.lowerBound), quickPasteHoldDurationRange.upperBound)
    }

    private static func clampQuickPasteEntryCount(_ value: Int) -> Int {
        min(max(value, quickPasteEntryCountRange.lowerBound), quickPasteEntryCountRange.upperBound)
    }

    /// The load-time half of the trigger-pair rule. Recording wins, because it is the
    /// setting that existed first and the one the user has been using.
    static func resolveQuickPasteTrigger(
        _ candidate: TriggerKey,
        recordingTrigger: TriggerKey
    ) -> TriggerKey {
        guard candidate == recordingTrigger else { return candidate }
        return TriggerKey.allCases.first { $0 != recordingTrigger } ?? candidate
    }

    public var quickPasteConfiguration: QuickPasteConfiguration {
        QuickPasteConfiguration(
            isEnabled: quickPasteEnabled,
            trigger: quickPasteTriggerKey,
            holdDuration: quickPasteHoldDuration,
            visibleEntryCount: quickPasteEntryCount
        )
    }

    /// The provider transcription runs on right now, as the id usage stats are keyed by.
    public var currentTranscriptionProviderID: String {
        provider.rawValue
    }

    /// The model of the selected provider. The one source for "which model is current":
    /// the coordinator and the popover header both read it here, so a view that observes
    /// this store re-renders with the new model the moment either setting changes.
    public var currentTranscriptionModelID: String {
        switch provider {
        case .openai:
            openAIModel.rawValue
        case .groq:
            groqModel.rawValue
        }
    }

    public var hotkeyConfig: HotkeyConfig {
        HotkeyConfig(
            trigger: triggerKey,
            mode: triggerMode,
            escapeToCancelRecording: escapeToCancelRecording
        )
    }

    /// Returns once the API keys read at launch have been applied.
    public func waitForAPIKeys() async {
        await apiKeyLoad?.value
    }

    /// Runs the reads on a dispatch queue rather than the cooperative pool, because a
    /// pending Keychain prompt can hold the calling thread for minutes.
    nonisolated private static func readAPIKeys(
        from keychain: KeychainStorage
    ) async -> [TranscriptionProviderID: String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var keys: [TranscriptionProviderID: String] = [:]
                for id in TranscriptionProviderID.allCases {
                    keys[id] = loadAPIKey(for: id, keychain: keychain)
                }
                continuation.resume(returning: keys)
            }
        }
    }

    private func applyLoadedAPIKeys(_ keys: [TranscriptionProviderID: String]) {
        loading = true
        defer { loading = false }
        for (id, key) in keys where !editedAPIKeys.contains(id) {
            switch id {
            case .openai:
                openAIAPIKey = key
            case .groq:
                groqAPIKey = key
            }
        }
    }

    nonisolated private static func loadAPIKey(for id: TranscriptionProviderID, keychain: KeychainStorage) -> String {
        if let value = (try? keychain.read(service: id.keychainService, account: id.keychainAccount)), !value.isEmpty {
            return value
        }
        return ""
    }

    public var hasPendingInstallWelcome: Bool {
        guard let pendingID = installMarkerString(forKey: DefaultsKey.pendingInstallWelcomeID),
              !pendingID.isEmpty
        else { return false }

        return installMarkerString(forKey: DefaultsKey.presentedInstallWelcomeID) != pendingID
    }

    public func markInstallWelcomePresented() {
        guard let pendingID = installMarkerString(forKey: DefaultsKey.pendingInstallWelcomeID),
              !pendingID.isEmpty
        else { return }

        defaults.set(pendingID, forKey: DefaultsKey.presentedInstallWelcomeID)
        defaults.removeObject(forKey: DefaultsKey.pendingInstallWelcomeID)
        installMarkerDefaults?.set(pendingID, forKey: DefaultsKey.presentedInstallWelcomeID)
        installMarkerDefaults?.removeObject(forKey: DefaultsKey.pendingInstallWelcomeID)
    }

    private func installMarkerString(forKey key: String) -> String? {
        defaults.string(forKey: key) ?? installMarkerDefaults?.string(forKey: key)
    }

    private func persistAPIKey(_ key: String, for id: TranscriptionProviderID) {
        if key.isEmpty {
            try? keychain.delete(service: id.keychainService, account: id.keychainAccount)
        } else {
            try? keychain.write(key, service: id.keychainService, account: id.keychainAccount)
        }
    }

    public func deleteAPIKey(for id: TranscriptionProviderID) {
        switch id {
        case .openai:
            openAIAPIKey = ""
        case .groq:
            groqAPIKey = ""
        }
        try? keychain.delete(service: id.keychainService, account: id.keychainAccount)
    }

    public func apiKey(for id: TranscriptionProviderID) -> String {
        switch id {
        case .openai: openAIAPIKey
        case .groq: groqAPIKey
        }
    }

    /// When the provider refused the stored key, or nil when it has not since the key
    /// was saved.
    public func apiKeyRejectedAt(for id: TranscriptionProviderID) -> Date? {
        apiKeyRejections[id]
    }

    /// A transcription with `apiKey` on `id` failed with `category`. Only a refusal of
    /// the key marks it; a network, timeout, rate-limit, quota or server failure says
    /// nothing about the key.
    public func recordTranscriptionFailure(
        _ category: TranscriptionError.Category,
        provider id: TranscriptionProviderID,
        apiKey: String,
        at date: Date = Date()
    ) {
        guard category == .unauthorized, !apiKey.isEmpty, apiKey == self.apiKey(for: id) else { return }
        setAPIKeyRejectedAt(date, for: id)
    }

    /// The one check at launch: once the stored keys have loaded, asks the selected
    /// provider whether its key still works. Only a clear refusal marks the key; an
    /// unavailable answer changes nothing, so a launch before the network is up raises
    /// no false alarm. An accepted key loses a stale mark.
    public func checkStoredAPIKeyAtLaunch(
        validator: APIKeyValidator,
        now: @Sendable () -> Date = { Date() }
    ) async -> LaunchAPIKeyCheckOutcome {
        await waitForAPIKeys()
        let id = provider
        let key = apiKey(for: id)
        guard !key.isEmpty else { return .skipped }

        let result = await validator(id, key)
        // A key saved or deleted while the request was out is not the one it judged.
        guard key == apiKey(for: id) else { return .skipped }

        switch result {
        case .accepted:
            setAPIKeyRejectedAt(nil, for: id)
            return .accepted
        case .rejected:
            setAPIKeyRejectedAt(now(), for: id)
            return .rejected
        case .unavailable:
            return .unavailable
        }
    }

    private func setAPIKeyRejectedAt(_ date: Date?, for id: TranscriptionProviderID) {
        guard apiKeyRejections[id] != date else { return }
        apiKeyRejections[id] = date
        if let date {
            defaults.set(date, forKey: DefaultsKey.apiKeyRejectedAt(id))
        } else {
            defaults.removeObject(forKey: DefaultsKey.apiKeyRejectedAt(id))
        }
    }

    public func makeTranscriptionProvider() -> TranscriptionProvider? {
        switch provider {
        case .openai:
            guard !openAIAPIKey.isEmpty else { return nil }
            return OpenAIProvider(apiKey: openAIAPIKey, model: openAIModel)
        case .groq:
            guard !groqAPIKey.isEmpty else { return nil }
            return GroqProvider(apiKey: groqAPIKey, model: groqModel)
        }
    }
}
