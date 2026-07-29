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

public enum ToastStyle: Sendable, Equatable {
    case warning
    case information
}

public struct ToastContent: Sendable, Equatable {
    public let message: String
    public let action: ToastAction
    public let style: ToastStyle

    public init(message: String, action: ToastAction, style: ToastStyle = .warning) {
        self.message = message
        self.action = action
        self.style = style
    }
}

public enum ToastDecision {

    public static func action(for reason: ToastReason, hasCachedAudio: Bool) -> ToastAction {
        switch reason {
        case .transcription(let category):
            switch category {
            case .network, .timedOut, .rateLimit, .serverError:
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

    public static func content(
        reason: ToastReason,
        message: String,
        hasCachedAudio: Bool,
        style: ToastStyle = .warning
    ) -> ToastContent {
        ToastContent(
            message: message,
            action: action(for: reason, hasCachedAudio: hasCachedAudio),
            style: style
        )
    }
}
