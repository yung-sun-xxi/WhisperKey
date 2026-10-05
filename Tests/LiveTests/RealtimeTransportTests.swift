import XCTest
@testable import Live

final class RealtimeTransportTests: XCTestCase {

    func testRequestTargetsTheRealtimeWebSocketWithTheModel() {
        let request = RealtimeTransport.makeRequest(apiKey: "sk-test", model: "gpt-realtime-2.1")
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
    }

    func testRequestAuthenticatesWithTheBearerKey() {
        let request = RealtimeTransport.makeRequest(apiKey: "sk-test", model: "gpt-realtime-2.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testRequestDoesNotSendTheBetaHeader() {
        // The GA interface rejects beta-shaped events; the header selects the beta interface.
        let request = RealtimeTransport.makeRequest(apiKey: "sk-test", model: "gpt-realtime-2.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
    }

    func testModelIsQueryEncoded() {
        let request = RealtimeTransport.makeRequest(apiKey: "k", model: "a b&c")
        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=a%20b%26c")
    }

    func testHandshakeStatusMapping() {
        XCTAssertEqual(RealtimeTransportError.handshake(statusCode: 401), .apiKeyRejected)
        XCTAssertEqual(RealtimeTransportError.handshake(statusCode: 403), .handshakeFailed(statusCode: 403))
        XCTAssertEqual(RealtimeTransportError.handshake(statusCode: 500), .handshakeFailed(statusCode: 500))
    }

    func testCloseMapping() {
        XCTAssertEqual(RealtimeTransportError.close(code: 1008, reason: "Incorrect API key provided"), .apiKeyRejected)
        XCTAssertEqual(RealtimeTransportError.close(code: 1008, reason: "invalid_api_key"), .apiKeyRejected)
        XCTAssertEqual(RealtimeTransportError.close(code: 1000, reason: nil), .closed(code: 1000, reason: nil))
        XCTAssertEqual(RealtimeTransportError.closed(code: 1000, reason: nil).message, "OpenAI closed the Live connection (code 1000)")
        XCTAssertEqual(RealtimeTransportError.closed(code: 1011, reason: "busy").message, "OpenAI closed the Live connection: busy")
    }

    func testErrorMessages() {
        XCTAssertEqual(RealtimeTransportError.apiKeyRejected.message, "OpenAI rejected the API key")
        XCTAssertEqual(
            RealtimeTransportError.handshakeFailed(statusCode: 500).message,
            "OpenAI refused the Live connection (HTTP 500)"
        )
        XCTAssertEqual(RealtimeTransportError.connectionLost("timed out").message, "Live connection lost: timed out")
        XCTAssertEqual(RealtimeTransportError.notConnected.message, "Live is not connected")
    }
}
