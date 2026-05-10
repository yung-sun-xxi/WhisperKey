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
    }

    public static let defaultHistoryMaxEntries = 30
    public static let historyMaxEntriesRange: ClosedRange<Int> = 0...1000

    private enum LegacyKeychain {
        static let service = "WhisperKey"
        static let account = "OPENAI_API_KEY"
    }

    private let keychain: KeychainStorage
    private let defaults: UserDefaults
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

        self.provider = (defaults.string(forKey: DefaultsKey.provider).flatMap(TranscriptionProviderID.init(rawValue:))) ?? .openai
        self.openAIModel = (defaults.string(forKey: DefaultsKey.openAIModel).flatMap(OpenAIProvider.Model.init(rawValue:))) ?? .whisper1
        self.groqModel = (defaults.string(forKey: DefaultsKey.groqModel).flatMap(GroqProvider.Model.init(rawValue:))) ?? .whisperLargeV3Turbo
        self.language = (defaults.string(forKey: DefaultsKey.language).flatMap(TranscriptionLanguage.init(rawValue:))) ?? .auto
        self.triggerKey = (defaults.string(forKey: DefaultsKey.triggerKey).flatMap(TriggerKey.init(rawValue:))) ?? .rightOption
        self.triggerMode = (defaults.string(forKey: DefaultsKey.triggerMode).flatMap(TriggerMode.init(rawValue:))) ?? .tap
        self.soundEffectsEnabled = (defaults.object(forKey: DefaultsKey.soundEffectsEnabled) as? Bool) ?? true
        let storedHistoryMax = (defaults.object(forKey: DefaultsKey.historyMaxEntries) as? Int) ?? Self.defaultHistoryMaxEntries
        self.historyMaxEntries = Self.clampHistoryMax(storedHistoryMax)
        self.openAIAPIKey = Self.loadOpenAIAPIKey(keychain: keychain)
        self.groqAPIKey = Self.loadAPIKey(for: .groq, keychain: keychain)

        self.loading = false
    }

    private static func clampHistoryMax(_ value: Int) -> Int {
        min(max(value, historyMaxEntriesRange.lowerBound), historyMaxEntriesRange.upperBound)
    }

    public var hotkeyConfig: HotkeyConfig {
        HotkeyConfig(trigger: triggerKey, mode: triggerMode)
    }

    private static func loadAPIKey(for id: TranscriptionProviderID, keychain: KeychainStorage) -> String {
        if let value = (try? keychain.read(service: id.keychainService, account: id.keychainAccount)), !value.isEmpty {
            return value
        }
        return ""
    }

    private static func loadOpenAIAPIKey(keychain: KeychainStorage) -> String {
        let id = TranscriptionProviderID.openai
        if let value = (try? keychain.read(service: id.keychainService, account: id.keychainAccount)), !value.isEmpty {
            return value
        }
        if let legacy = (try? keychain.read(service: LegacyKeychain.service, account: LegacyKeychain.account)), !legacy.isEmpty {
            try? keychain.write(legacy, service: id.keychainService, account: id.keychainAccount)
            return legacy
        }
        return ""
    }

    private func persistAPIKey(_ key: String, for id: TranscriptionProviderID) {
        if key.isEmpty {
            try? keychain.delete(service: id.keychainService, account: id.keychainAccount)
        } else {
            try? keychain.write(key, service: id.keychainService, account: id.keychainAccount)
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
