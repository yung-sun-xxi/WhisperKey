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

    public var keychainService: String { "WhisperKey.\(rawValue)" }
    public var keychainAccount: String { "apiKey" }
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
        static let pauseAppleMusicWhileRecording = "WhisperKey.settings.pauseAppleMusicWhileRecording"
        static let pendingInstallWelcomeID = "WhisperKey.settings.pendingInstallWelcomeID"
        static let presentedInstallWelcomeID = "WhisperKey.settings.presentedInstallWelcomeID"
        static let usageStatsRange = "WhisperKey.settings.usageStatsRange"
        // The enabled key is the one #79 wrote by hand as a hidden flag, kept so anyone
        // who turned it on that way keeps the feature on.
        static let quickPasteEnabled = "WhisperKey.settings.quickPasteEnabled"
        static let quickPasteTriggerKey = "WhisperKey.settings.quickPasteTriggerKey"
        static let quickPasteHoldDuration = "WhisperKey.settings.quickPasteHoldDuration"
        static let quickPasteEntryCount = "WhisperKey.settings.quickPasteEntryCount"
    }

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

    @Published public var pauseAppleMusicWhileRecording: Bool {
        didSet {
            if !loading {
                defaults.set(pauseAppleMusicWhileRecording, forKey: DefaultsKey.pauseAppleMusicWhileRecording)
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

    @Published public var openAIAPIKey: String {
        didSet { if !loading { persistAPIKey(openAIAPIKey, for: .openai) } }
    }

    @Published public var groqAPIKey: String {
        didSet { if !loading { persistAPIKey(groqAPIKey, for: .groq) } }
    }

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
        self.openAIModel = (defaults.string(forKey: DefaultsKey.openAIModel).flatMap(OpenAIProvider.Model.init(rawValue:))) ?? .whisper1
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
        self.pauseAppleMusicWhileRecording = (defaults.object(forKey: DefaultsKey.pauseAppleMusicWhileRecording) as? Bool) ?? true
        let storedHistoryMax = (defaults.object(forKey: DefaultsKey.historyMaxEntries) as? Int) ?? Self.defaultHistoryMaxEntries
        self.historyMaxEntries = Self.clampHistoryMax(storedHistoryMax)
        self.usageStatsRange = (defaults.string(forKey: DefaultsKey.usageStatsRange).flatMap(UsageStatsRange.init(rawValue:))) ?? .today
        self.quickPasteEnabled = (defaults.object(forKey: DefaultsKey.quickPasteEnabled) as? Bool) ?? false
        let storedHoldDuration = (defaults.object(forKey: DefaultsKey.quickPasteHoldDuration) as? Double)
            ?? Self.defaultQuickPasteHoldDuration
        self.quickPasteHoldDuration = Self.clampQuickPasteHoldDuration(storedHoldDuration)
        let storedEntryCount = (defaults.object(forKey: DefaultsKey.quickPasteEntryCount) as? Int)
            ?? Self.defaultQuickPasteEntryCount
        self.quickPasteEntryCount = Self.clampQuickPasteEntryCount(storedEntryCount)
        self.openAIAPIKey = Self.loadAPIKey(for: .openai, keychain: keychain)
        self.groqAPIKey = Self.loadAPIKey(for: .groq, keychain: keychain)

        self.loading = false
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

    public var hotkeyConfig: HotkeyConfig {
        HotkeyConfig(
            trigger: triggerKey,
            mode: triggerMode,
            escapeToCancelRecording: escapeToCancelRecording
        )
    }

    private static func loadAPIKey(for id: TranscriptionProviderID, keychain: KeychainStorage) -> String {
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
