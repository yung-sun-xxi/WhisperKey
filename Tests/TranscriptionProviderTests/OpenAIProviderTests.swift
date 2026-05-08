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

private extension Data {
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

    // MARK: Error mapping

    func testUnauthorizedMapsTo401() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 401, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .unauthorized)
    }

    func testForbiddenMapsToUnauthorized() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 403, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .unauthorized)
    }

    func testRateLimitMapsTo429() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 429, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .rateLimit)
    }

    func testServerErrorMapsTo5xx() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 503, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .serverError(status: 503))
    }

    func testClientErrorMapsTo4xxOther() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 422, body: Data(), headers: [:]))
        let provider = makeProvider()
        await assertThrows(provider, expected: .clientError(status: 422))
    }

    func testNetworkFailureMapsToNetwork() async {
        StubURLProtocol.nextOutcome = .failure(URLError(.notConnectedToInternet))
        let provider = makeProvider()
        await assertThrows(provider, expected: .network)
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
