import Foundation
import AudioEncoder
import os

private let groqProviderLog = Logger(subsystem: "WhisperKey", category: "GroqProvider")

public struct GroqProvider: TranscriptionProvider {

    public enum Model: String, Sendable, Equatable, CaseIterable {
        case whisperLargeV3 = "whisper-large-v3"
        case whisperLargeV3Turbo = "whisper-large-v3-turbo"
        case distilWhisperLargeV3EN = "distil-whisper-large-v3-en"

        public var displayName: String {
            switch self {
            case .whisperLargeV3: return "whisper-large-v3"
            case .whisperLargeV3Turbo: return "whisper-large-v3-turbo (faster)"
            case .distilWhisperLargeV3EN: return "distil-whisper-large-v3-en (English-only)"
            }
        }
    }

    public static let defaultEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    public let apiKey: String
    public let model: Model
    public let endpoint: URL
    public let urlSession: URLSession
    private let boundaryProvider: @Sendable () -> String

    public init(
        apiKey: String,
        model: Model = .whisperLargeV3Turbo,
        endpoint: URL = GroqProvider.defaultEndpoint,
        urlSession: URLSession = .shared,
        boundaryProvider: @escaping @Sendable () -> String = { "WhisperKey-\(UUID().uuidString)" }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.boundaryProvider = boundaryProvider
    }

    public func transcribe(audio: EncodedAudio, language: String?) async throws -> String {
        let boundary = boundaryProvider()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = WhisperMultipartBody.make(
            boundary: boundary,
            audio: audio,
            model: model.rawValue,
            language: language
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw TranscriptionError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.unknown
        }

        groqProviderLog.info("transcription response provider=groq model=\(model.rawValue, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")

        if let mapped = WhisperResponseParser.mapHTTPStatus(http.statusCode, data: data) {
            throw mapped
        }
        return try WhisperResponseParser.parseSuccess(data)
    }
}
