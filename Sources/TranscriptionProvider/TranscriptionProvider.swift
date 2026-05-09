import Foundation
import AudioEncoder

public enum TranscriptionError: Error, Equatable {
    case network
    case rateLimit(message: String?)
    case quotaExceeded(message: String?)
    case unauthorized(message: String?)
    case serverError(status: Int, message: String?)
    case clientError(status: Int, message: String?)
    case unknown
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network:
            return "Network error — check your internet connection."
        case .rateLimit(let message):
            return message ?? "Rate limit reached — please try again in a moment."
        case .quotaExceeded(let message):
            let suffix = "Top up at platform.openai.com/billing."
            if let message, !message.isEmpty {
                return "\(message) \(suffix)"
            }
            return "OpenAI quota exceeded. \(suffix)"
        case .unauthorized(let message):
            return message ?? "Invalid API key — update it in Settings."
        case .serverError(let status, let message):
            return message ?? "OpenAI server error (HTTP \(status)). Try again later."
        case .clientError(let status, let message):
            return message ?? "Request rejected by OpenAI (HTTP \(status))."
        case .unknown:
            return "Unknown transcription error."
        }
    }
}

public protocol TranscriptionProvider: Sendable {
    func transcribe(audio: EncodedAudio, language: String?) async throws -> String
}
