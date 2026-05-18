import Foundation

public enum APIKeyValidationResult: Sendable, Equatable {
    case accepted
    case acceptedWithWarning(message: String)
    case rejected(message: String)
    case unavailable(message: String)

    public var isAccepted: Bool {
        switch self {
        case .accepted, .acceptedWithWarning:
            return true
        case .rejected, .unavailable:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .accepted:
            return "API key accepted."
        case .acceptedWithWarning(let message), .rejected(let message), .unavailable(let message):
            return message
        }
    }
}

enum APIKeyValidator {
    static func validate(
        apiKey: String,
        modelsEndpoint: URL,
        providerDisplayName: String,
        urlSession: URLSession
    ) async -> APIKeyValidationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .rejected(message: "Enter an API key.")
        }

        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            return .unavailable(message: "Could not verify the API key. Check your internet connection.")
        }

        guard let http = response as? HTTPURLResponse else {
            return .unavailable(message: "Could not verify the API key. Unexpected response from \(providerDisplayName).")
        }

        let serverMessage = WhisperResponseParser.parseError(data)?.message
        switch http.statusCode {
        case 200..<300:
            return .accepted
        case 401:
            return .rejected(message: serverMessage ?? "Invalid API key.")
        case 403:
            return .rejected(message: serverMessage ?? "API key is valid, but it does not have access to \(providerDisplayName).")
        case 429:
            return .acceptedWithWarning(
                message: serverMessage ?? "API key accepted, but \(providerDisplayName) is rate limiting validation."
            )
        case 500..<600:
            return .unavailable(message: serverMessage ?? "\(providerDisplayName) is unavailable. Try again later.")
        case 400..<500:
            return .rejected(message: serverMessage ?? "\(providerDisplayName) rejected this API key.")
        default:
            return .unavailable(message: serverMessage ?? "Could not verify the API key.")
        }
    }
}
