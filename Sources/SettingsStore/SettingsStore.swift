import Foundation
import Combine
import HotkeyEngine
import KeychainStore
import TranscriptionProvider

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
        static let pendingInstallWelcomeID = "WhisperKey.settings.pendingInstallWelcomeID"
        static let presentedInstallWelcomeID = "WhisperKey.settings.presentedInstallWelcomeID"
    }

    public static let defaultHistoryMaxEntries = 30
    public static let historyMaxEntriesRange: ClosedRange<Int> = 0...1000

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

    @Published public var triggerKey: TriggerKey {
        didSet { if !loading { defaults.set(triggerKey.rawValue, forKey: DefaultsKey.triggerKey) } }
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
        self.triggerKey = (defaults.string(forKey: DefaultsKey.triggerKey).flatMap(TriggerKey.init(rawValue:))) ?? .rightOption
        self.triggerMode = (defaults.string(forKey: DefaultsKey.triggerMode).flatMap(TriggerMode.init(rawValue:))) ?? .tap
        self.soundEffectsEnabled = (defaults.object(forKey: DefaultsKey.soundEffectsEnabled) as? Bool) ?? true
        self.saveTranscriptionToClipboard = (defaults.object(forKey: DefaultsKey.saveTranscriptionToClipboard) as? Bool) ?? true
        self.autoPasteTranscription = (defaults.object(forKey: DefaultsKey.autoPasteTranscription) as? Bool) ?? true
        self.escapeToCancelRecording = (defaults.object(forKey: DefaultsKey.escapeToCancelRecording) as? Bool) ?? true
        let storedHistoryMax = (defaults.object(forKey: DefaultsKey.historyMaxEntries) as? Int) ?? Self.defaultHistoryMaxEntries
        self.historyMaxEntries = Self.clampHistoryMax(storedHistoryMax)
        self.openAIAPIKey = Self.loadAPIKey(for: .openai, keychain: keychain)
        self.groqAPIKey = Self.loadAPIKey(for: .groq, keychain: keychain)

        self.loading = false
    }

    private static func clampHistoryMax(_ value: Int) -> Int {
        min(max(value, historyMaxEntriesRange.lowerBound), historyMaxEntriesRange.upperBound)
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
