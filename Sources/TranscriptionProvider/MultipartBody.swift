import Foundation
import AudioEncoder

/// Builds an OpenAI-compatible Whisper multipart/form-data body. Groq's REST endpoint
/// is wire-compatible with OpenAI's, so this construction is shared between the two
/// providers.
enum WhisperMultipartBody {

    static func make(boundary: String, audio: EncodedAudio, model: String, language: String?) -> Data {
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
}

enum WhisperResponseParser {

    static func parseSuccess(_ data: Data) throws -> String {
        struct Payload: Decodable { let text: String }
        do {
            return try JSONDecoder().decode(Payload.self, from: data).text
        } catch {
            throw TranscriptionError.unknown
        }
    }

    struct ErrorBody: Decodable {
        let message: String?
        let code: String?
    }

    static func parseError(_ data: Data) -> ErrorBody? {
        struct Envelope: Decodable {
            let error: ErrorBody?
        }
        guard !data.isEmpty,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return nil
        }
        return envelope.error
    }

    static func mapHTTPStatus(
        _ status: Int,
        data: Data,
        rateLimitQuotaCode: String = "insufficient_quota"
    ) -> TranscriptionError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized(message: parseError(data)?.message)
        case 429:
            let parsed = parseError(data)
            if parsed?.code == rateLimitQuotaCode {
                return .quotaExceeded(message: parsed?.message)
            }
            return .rateLimit(message: parsed?.message)
        case 500..<600:
            return .serverError(status: status, message: parseError(data)?.message)
        case 400..<500:
            return .clientError(status: status, message: parseError(data)?.message)
        default:
            return .unknown
        }
    }
}
