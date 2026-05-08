import Foundation
import AudioEncoder

public enum TranscriptionError: Error, Equatable {
    case network
    case rateLimit
    case unauthorized
    case serverError(status: Int)
    case clientError(status: Int)
    case unknown
}

public protocol TranscriptionProvider: Sendable {
    func transcribe(audio: EncodedAudio, language: String?) async throws -> String
}
