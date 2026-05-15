import XCTest
@testable import TranscriptionProvider
import AudioEncoder

final class GroqProviderTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeProvider(
        model: GroqProvider.Model = .whisperLargeV3Turbo,
        boundary: String = "BOUNDARY-G"
    ) -> GroqProvider {
        GroqProvider(
            apiKey: "gsk-test",
            model: model,
            urlSession: makeSession(),
            boundaryProvider: { boundary }
        )
    }

    private let sampleAudio = EncodedAudio(
        data: Data([0xBA, 0xAD, 0xF0, 0x0D]),
        mimeType: "audio/wav",
        fileExtension: "wav"
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testHitsGroqEndpoint() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":"groq says hi"}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let provider = makeProvider()
        let result = try await provider.transcribe(audio: sampleAudio, language: nil)
        XCTAssertEqual(result, "groq says hi")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url, GroqProvider.defaultEndpoint)
        XCTAssertEqual(request.url?.host, "api.groq.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test")
    }

    func testRequestBodyIncludesModelAndLanguage() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":"ok"}"#.data(using: .utf8)!,
            headers: [:]
        ))

        let provider = makeProvider(model: .whisperLargeV3)
        _ = try await provider.transcribe(audio: sampleAudio, language: "ru")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertTrue(body.contains(ascii: "--BOUNDARY-G"))
        XCTAssertTrue(body.contains(ascii: "name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains(ascii: "name=\"model\""))
        XCTAssertTrue(body.contains(ascii: "whisper-large-v3"))
        XCTAssertTrue(body.contains(ascii: "name=\"language\""))
        XCTAssertTrue(body.contains(ascii: "\r\n\r\nru\r\n"))
    }

    func testLanguageOmittedWhenNil() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":"x"}"#.data(using: .utf8)!,
            headers: [:]
        ))

        let provider = makeProvider()
        _ = try await provider.transcribe(audio: sampleAudio, language: nil)

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        XCTAssertFalse(body.contains(ascii: "name=\"language\""))
    }

    func testEmptyTextResponseIsReturnedAsProviderSuccess() async throws {
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 200,
            body: #"{"text":""}"#.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))

        let result = try await makeProvider().transcribe(audio: sampleAudio, language: nil)

        XCTAssertEqual(result, "")
    }

    // MARK: - Error mapping (shared parser)

    func testUnauthorizedMaps() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 401, body: Data(), headers: [:]))
        await assertThrows(makeProvider(), expected: .unauthorized(message: nil))
    }

    func testRateLimitMaps() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 429, body: Data(), headers: [:]))
        await assertThrows(makeProvider(), expected: .rateLimit(message: nil))
    }

    func testRateLimitParsesGroqMessage() async {
        let body = #"{"error":{"message":"Too many requests","code":"rate_limit_exceeded"}}"#
        StubURLProtocol.nextOutcome = .http(.init(
            statusCode: 429,
            body: body.data(using: .utf8)!,
            headers: ["Content-Type": "application/json"]
        ))
        await assertThrows(makeProvider(), expected: .rateLimit(message: "Too many requests"))
    }

    func testServerErrorMaps() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 502, body: Data(), headers: [:]))
        await assertThrows(makeProvider(), expected: .serverError(status: 502, message: nil))
    }

    func testClientErrorMaps() async {
        StubURLProtocol.nextOutcome = .http(.init(statusCode: 413, body: Data(), headers: [:]))
        await assertThrows(makeProvider(), expected: .clientError(status: 413, message: nil))
    }

    func testNetworkFailureMaps() async {
        StubURLProtocol.nextOutcome = .failure(URLError(.cannotConnectToHost))
        await assertThrows(makeProvider(), expected: .network)
    }

    private func assertThrows(_ provider: GroqProvider, expected: TranscriptionError, file: StaticString = #filePath, line: UInt = #line) async {
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
