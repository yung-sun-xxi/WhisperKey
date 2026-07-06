import XCTest
@testable import TranscriptionProvider
import AudioEncoder

// MARK: - URLProtocol-based mock transport

final class StubURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int
        var body: Data
        var headers: [String: String]
    }

    /// Either an HTTP response to return, or an error to fail with.
    enum Outcome {
        case http(Response)
        case failure(Error)
        case stall
    }

    nonisolated(unsafe) static var nextOutcome: Outcome?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        nextOutcome = nil
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.bodyStreamData()

        guard let outcome = Self.nextOutcome else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .stall:
            break
        case .http(let response):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

extension Data {
    func contains(ascii: String) -> Bool {
        guard let needle = ascii.data(using: .ascii) else { return false }
        return range(of: needle) != nil
    }

    func contains(bytes: [UInt8]) -> Bool {
        range(of: Data(bytes)) != nil
    }
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Tests

final class OpenAIProviderTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeProvider(model: OpenAIProvider.Model = .whisper1, boundary: String = "BOUNDARY-FIXED") -> OpenAIProvider {
        OpenAIProvider(
            apiKey: "sk-test-key",
            model: model,
            urlSession: makeSession(),
            boundaryProvider: { boundary }
        )
    }

    private func makeProvider(requestTimeout: TimeInterval) -> OpenAIProvider {
        OpenAIProvider(
            apiKey: "sk-test-key",
            urlSession: makeSession(),
            requestTimeout: requestTimeout,
            boundaryProvider: { "BOUNDARY-FIXED" }
        )
    }

    private let sampleAudio = EncodedAudio(
        data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
        mimeType: "audio/wav",
        fileExtension: "wav"
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Request shape

    func testRequestShapeIncludesAuthAndMultipartBody() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":"hello world"}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let provider = makeProvider()
        let result = try await provider.transcribe(audio: sampleAudio, language: nil)

        XCTAssertEqual(result, "hello world")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, OpenAIProvider.defaultEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "multipart/form-data; boundary=BOUNDARY-FIXED"
        )

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertTrue(body.contains(ascii: "--BOUNDARY-FIXED"))
        XCTAssertTrue(body.contains(ascii: "name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains(ascii: "Content-Type: audio/wav"))
        XCTAssertTrue(body.contains(ascii: "name=\"model\""))
        XCTAssertTrue(body.contains(ascii: "whisper-1"))
        XCTAssertFalse(body.contains(ascii: "name=\"language\""), "no language hint should be sent when nil")
        XCTAssertTrue(body.contains(bytes: [0xDE, 0xAD, 0xBE, 0xEF]), "audio payload bytes preserved verbatim")
    }

    func testLanguageParameterIsIncludedWhenProvided() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":"привет"}"#.data(using: .utf8)!,
            headers: [:]
        ))

        let provider = makeProvider()
        _ = try await provider.transcribe(audio: sampleAudio, language: "ru")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertTrue(body.contains(ascii: "name=\"language\""))
        XCTAssertTrue(body.contains(ascii: "\r\n\r\nru\r\n"))
    }

    func testEmptyTextResponseIsReturnedAsProviderSuccess() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":""}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let provider = makeProvider()
        let result = try await provider.transcribe(audio: sampleAudio, language: nil)

        XCTAssertEqual(result, "")
    }

    // MARK: Error mapping

    func testUnauthorizedMapsTo401() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 401, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .unauthorized(message: nil))
    }

    func testForbiddenMapsToUnauthorized() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 403, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .unauthorized(message: nil))
    }

    func testRateLimitMapsTo429() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 429, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .rateLimit(message: nil))
    }

    func testRateLimitParsesServerMessage() async {
        let body = #"{"error":{"message":"Rate limit reached for whisper-1","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 429,
            body: body.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))
        let provider = makeProvider()
        await assertThrows(provider, expected: .rateLimit(message: "Rate limit reached for whisper-1"))
    }

    func testInsufficientQuotaMapsToQuotaExceeded() async {
        let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 429,
            body: body.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))
        let provider = makeProvider()
        await assertThrows(provider, expected: .quotaExceeded(message: "You exceeded your current quota."))
    }

    func testUnauthorizedParsesServerMessage() async {
        let body = #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 401,
            body: body.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))
        let provider = makeProvider()
        await assertThrows(provider, expected: .unauthorized(message: "Incorrect API key provided."))
    }

    func testServerErrorMapsTo5xx() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 503, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .serverError(status: 503, message: nil))
    }

    func testClientErrorMapsTo4xxOther() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 422, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .clientError(status: 422, message: nil))
    }

    func testNetworkFailureMapsToNetwork() async {
        StubURLProtocol.nextOutcome = .failure(URLError(.notConnectedToInternet))
        let provider = makeProvider()
        await assertThrows(provider, expected: .network)
    }

    func testStalledRequestMapsToTimeout() async {
        StubURLProtocol.nextOutcome = .stall
        let provider = makeProvider(requestTimeout: 0.01)
        await assertThrows(provider, expected: .timedOut)
    }

    // MARK: API key validation

    func testValidateAPIKeyAcceptsSuccessfulModelsResponse() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"object":"list","data":[]}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let result = await OpenAIProvider.validateAPIKey(" sk-test-key\n", urlSession: makeSession())

        XCTAssertEqual(result, .accepted)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, OpenAIProvider.defaultModelsEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testValidateAPIKeyRejectsUnauthorizedResponse() async {
        let body = #"{"error":{"message":"Incorrect API key provided.","code":"invalid_api_key"}}"#
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 401,
            body: body.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let result = await OpenAIProvider.validateAPIKey("sk-bad", urlSession: makeSession())

        XCTAssertEqual(result, .rejected(message: "Incorrect API key provided."))
    }

    func testValidateAPIKeyTreatsRateLimitAsAcceptedWithWarning() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 429, body: Data(), headers: [:]))

        let result = await OpenAIProvider.validateAPIKey("sk-rate-limited", urlSession: makeSession())

        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(result, .acceptedWithWarning(message: "API key accepted, but OpenAI is rate limiting validation."))
    }

    func testValidateAPIKeyReportsNetworkAsUnavailable() async {
        StubURLProtocol.nextOutcome = .failure(URLError(.notConnectedToInternet))

        let result = await OpenAIProvider.validateAPIKey("sk-network", urlSession: makeSession())

        XCTAssertEqual(
            result,
            .unavailable(message: "Could not verify the API key. Check your internet connection.")
        )
    }

    // MARK: LocalizedError

    func testQuotaExceededErrorDescriptionMentionsBilling() {
        let error = TranscriptionError.quotaExceeded(message: "You exceeded your current quota.")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("quota"))
        XCTAssertTrue(description.contains("platform.openai.com/billing"))
    }

    // MARK: Helpers

    private func assertThrows(_ provider: OpenAIProvider, expected: TranscriptionError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.transcribe(audio: sampleAudio, language: nil)
            XCTFail("Expected error, got success", file: file, line: line)
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Wrong error type: \(error)", file: file, line: line)
        }
    }
}
