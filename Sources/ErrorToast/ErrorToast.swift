import Foundation
import TranscriptionProvider

public enum ToastReason: Sendable, Equatable {
    case transcription(TranscriptionError.Category)
    case missingProvider
    case microphoneDenied
    case accessibilityDenied
    case recordingCaptureTimedOut
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

/// How long a toast stays on screen.
public enum ToastLifetime: Sendable, Equatable {
    /// Stays until the user closes it or presses its action. For anything that means a
    /// recording was lost: a banner that leaves on its own can be missed, and then the
    /// user believes the text was pasted.
    case untilDismissed
    /// Leaves on its own after a few seconds. For a report of something that is already
    /// over and needs no decision.
    case transient

    /// The default for a style. A warning is by definition something that went wrong,
    /// so it waits; information does not.
    public static func `default`(for style: ToastStyle) -> ToastLifetime {
        switch style {
        case .warning: .untilDismissed
        case .information: .transient
        }
    }
}

public struct ToastContent: Sendable, Equatable {
    public let message: String
    public let action: ToastAction
    public let style: ToastStyle
    public let lifetime: ToastLifetime

    public init(
        message: String,
        action: ToastAction,
        style: ToastStyle = .warning,
        lifetime: ToastLifetime? = nil
    ) {
        self.message = message
        self.action = action
        self.style = style
        self.lifetime = lifetime ?? .default(for: style)
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
        case .recordingCaptureTimedOut:
            return .none
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
