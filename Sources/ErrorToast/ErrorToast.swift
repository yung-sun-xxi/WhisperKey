import Foundation
import TranscriptionProvider

public enum ToastReason: Sendable, Equatable {
    case transcription(TranscriptionError.Category)
    case missingProvider
    case microphoneDenied
    case accessibilityDenied
}

public enum ToastAction: Sendable, Equatable {
    case retry
    case openSettings
    case none
}

public struct ToastContent: Sendable, Equatable {
    public let message: String
    public let action: ToastAction

    public init(message: String, action: ToastAction) {
        self.message = message
        self.action = action
    }
}

public enum ToastDecision {

    public static func action(for reason: ToastReason, hasCachedAudio: Bool) -> ToastAction {
        switch reason {
        case .transcription(let category):
            switch category {
            case .network, .rateLimit, .serverError:
                return hasCachedAudio ? .retry : .openSettings
            case .unauthorized, .quotaExceeded:
                return .openSettings
            case .clientError, .unknown:
                return .none
            }
        case .missingProvider, .microphoneDenied, .accessibilityDenied:
            return .openSettings
        }
    }

    public static func content(reason: ToastReason, message: String, hasCachedAudio: Bool) -> ToastContent {
        ToastContent(
            message: message,
            action: action(for: reason, hasCachedAudio: hasCachedAudio)
        )
    }
}
