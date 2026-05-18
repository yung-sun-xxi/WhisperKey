import Foundation
import AudioEncoder
import os

private let openAIProviderLog = Logger(subsystem: "WhisperKey", category: "OpenAIProvider")

public struct OpenAIProvider: TranscriptionProvider {

    public enum Model: String, Sendable, Equatable, CaseIterable {
        case whisper1 = "whisper-1"
        case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    }

    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let defaultModelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    public let apiKey: String
    public let model: Model
    public let endpoint: URL
    public let urlSession: URLSession
    private let boundaryProvider: @Sendable () -> String

    public init(
        apiKey: String,
        model: Model = .whisper1,
        endpoint: URL = OpenAIProvider.defaultEndpoint,
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

        openAIProviderLog.info("transcription response provider=openai model=\(model.rawValue, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)")

        if let mapped = WhisperResponseParser.mapHTTPStatus(http.statusCode, data: data) {
            throw mapped
        }
        return try WhisperResponseParser.parseSuccess(data)
    }

    public static func validateAPIKey(
        _ apiKey: String,
        modelsEndpoint: URL = OpenAIProvider.defaultModelsEndpoint,
        urlSession: URLSession = .shared
    ) async -> APIKeyValidationResult {
        await APIKeyValidator.validate(
            apiKey: apiKey,
            modelsEndpoint: modelsEndpoint,
            providerDisplayName: "OpenAI",
            urlSession: urlSession
        )
    }
}
