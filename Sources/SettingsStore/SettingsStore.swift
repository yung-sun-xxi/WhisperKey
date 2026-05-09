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

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI"
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
        static let language = "WhisperKey.settings.language"
        static let triggerKey = "WhisperKey.settings.triggerKey"
        static let triggerMode = "WhisperKey.settings.triggerMode"
    }

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

    @Published public var language: TranscriptionLanguage {
        didSet { if !loading { defaults.set(language.rawValue, forKey: DefaultsKey.language) } }
    }

    @Published public var triggerKey: TriggerKey {
        didSet { if !loading { defaults.set(triggerKey.rawValue, forKey: DefaultsKey.triggerKey) } }
    }

    @Published public var triggerMode: TriggerMode {
        didSet { if !loading { defaults.set(triggerMode.rawValue, forKey: DefaultsKey.triggerMode) } }
    }

    @Published public var openAIAPIKey: String {
        didSet { if !loading { persistOpenAIAPIKey() } }
    }

    public init(keychain: KeychainStorage = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults

        self.provider = (defaults.string(forKey: DefaultsKey.provider).flatMap(TranscriptionProviderID.init(rawValue:))) ?? .openai
        self.openAIModel = (defaults.string(forKey: DefaultsKey.openAIModel).flatMap(OpenAIProvider.Model.init(rawValue:))) ?? .whisper1
        self.language = (defaults.string(forKey: DefaultsKey.language).flatMap(TranscriptionLanguage.init(rawValue:))) ?? .auto
        self.triggerKey = (defaults.string(forKey: DefaultsKey.triggerKey).flatMap(TriggerKey.init(rawValue:))) ?? .rightOption
        self.triggerMode = (defaults.string(forKey: DefaultsKey.triggerMode).flatMap(TriggerMode.init(rawValue:))) ?? .tap
        self.openAIAPIKey = Self.loadOpenAIAPIKey(keychain: keychain)

        self.loading = false
    }

    public var hotkeyConfig: HotkeyConfig {
        HotkeyConfig(trigger: triggerKey, mode: triggerMode)
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

    private func persistOpenAIAPIKey() {
        let id = TranscriptionProviderID.openai
        let trimmed = openAIAPIKey
        if trimmed.isEmpty {
            try? keychain.delete(service: id.keychainService, account: id.keychainAccount)
        } else {
            try? keychain.write(trimmed, service: id.keychainService, account: id.keychainAccount)
        }
    }

    public func makeTranscriptionProvider() -> TranscriptionProvider? {
        switch provider {
        case .openai:
            guard !openAIAPIKey.isEmpty else { return nil }
            return OpenAIProvider(apiKey: openAIAPIKey, model: openAIModel)
        }
    }
}
