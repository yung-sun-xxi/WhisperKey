import HotkeyEngine

// Live is OpenAI-only. Of WhisperKey's transcription providers, only OpenAI offers realtime
// speech-to-speech, so the transcription-provider choice in settings does not apply to Live:
// Live always talks to OpenAI with the OpenAI key, whichever provider dictation uses.

/// Whether Live can be used, and if not, what to tell the user.
public enum LiveAvailability: Equatable, Sendable {
    case available
    /// The user has not turned Live on.
    case off
    /// No OpenAI key in the Keychain; the toggle is disabled.
    case needsOpenAIKey
    /// The trigger is Right Shift, where a chord with a character key would type a capital.
    case unavailableWithTrigger

    public static func evaluate(liveEnabled: Bool, hasOpenAIKey: Bool, trigger: TriggerKey) -> LiveAvailability {
        if !hasOpenAIKey { return .needsOpenAIKey }
        if trigger == .rightShift { return .unavailableWithTrigger }
        return liveEnabled ? .available : .off
    }

    public var isAvailable: Bool { self == .available }

    /// The line shown under the disabled toggle; nil when there is nothing to explain.
    public var message: String? {
        switch self {
        case .available, .off: return nil
        case .needsOpenAIKey: return "Live needs an OpenAI key"
        case .unavailableWithTrigger: return "Live is unavailable with the Right Shift trigger"
        }
    }
}
