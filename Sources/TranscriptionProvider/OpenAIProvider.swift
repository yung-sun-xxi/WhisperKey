import Foundation
import AudioEncoder

public struct OpenAIProvider: TranscriptionProvider {

    public enum Model: String, Sendable, Equatable, CaseIterable {
        case whisper1 = "whisper-1"
        case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    }

    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

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
        request.httpBody = Self.makeBody(boundary: boundary, audio: audio, model: model.rawValue, language: language)

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

        switch http.statusCode {
        case 200..<300:
            return try Self.parseSuccess(data)
        case 401, 403:
            throw TranscriptionError.unauthorized(message: Self.parseError(data)?.message)
        case 429:
            let parsed = Self.parseError(data)
            if parsed?.code == "insufficient_quota" {
                throw TranscriptionError.quotaExceeded(message: parsed?.message)
            }
            throw TranscriptionError.rateLimit(message: parsed?.message)
        case 500..<600:
            throw TranscriptionError.serverError(status: http.statusCode, message: Self.parseError(data)?.message)
        case 400..<500:
            throw TranscriptionError.clientError(status: http.statusCode, message: Self.parseError(data)?.message)
        default:
            throw TranscriptionError.unknown
        }
    }

    // MARK: - Body construction

    static func makeBody(boundary: String, audio: EncodedAudio, model: String, language: String?) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(audio.mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(audio.data)
        body.append(lineBreak.data(using: .utf8)!)

        appendField(name: "model", value: model)
        appendField(name: "response_format", value: "json")
        if let language, !language.isEmpty {
            appendField(name: "language", value: language)
        }

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }

    static func parseSuccess(_ data: Data) throws -> String {
        struct Payload: Decodable { let text: String }
        do {
            return try JSONDecoder().decode(Payload.self, from: data).text
        } catch {
            throw TranscriptionError.unknown
        }
    }

    struct OpenAIErrorBody: Decodable {
        let message: String?
        let code: String?
    }

    static func parseError(_ data: Data) -> OpenAIErrorBody? {
        struct Envelope: Decodable {
            let error: OpenAIErrorBody?
        }
        guard !data.isEmpty,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        return envelope.error
    }
}
