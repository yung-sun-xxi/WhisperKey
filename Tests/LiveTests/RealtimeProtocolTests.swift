import XCTest
@testable import Live

/// Fixtures are written out by hand from the OpenAI Realtime reference (GA interface,
/// checked 2026-10-05) rather than produced by the code under test, so a renamed field on
/// either side shows up as a failure here.
final class RealtimeProtocolTests: XCTestCase {

    // MARK: - Client events

    func testSessionUpdateEncodesTheGAShape() throws {
        let config = RealtimeSessionConfig(
            model: "gpt-realtime-2.1",
            instructions: "Be brief.",
            voice: "ash",
            transcriptionModel: "gpt-4o-mini-transcribe"
        )
        try assertJSON(
            RealtimeClientEvent.sessionUpdate(config),
            #"""
            {
              "type": "session.update",
              "session": {
                "type": "realtime",
                "instructions": "Be brief.",
                "output_modalities": ["audio"],
                "audio": {
                  "input": {
                    "format": { "type": "audio/pcm", "rate": 24000 },
                    "transcription": { "model": "gpt-4o-mini-transcribe" },
                    "turn_detection": {
                      "type": "semantic_vad",
                      "create_response": true,
                      "interrupt_response": true
                    }
                  },
                  "output": {
                    "format": { "type": "audio/pcm", "rate": 24000 },
                    "voice": "ash"
                  }
                }
              }
            }
            """#
        )
    }

    func testSessionConfigDefaults() {
        let config = RealtimeSessionConfig(instructions: "x")
        XCTAssertEqual(config.model, "gpt-realtime-2.1")
        XCTAssertEqual(config.voice, "ash")
        XCTAssertEqual(config.transcriptionModel, "gpt-4o-mini-transcribe")
    }

    func testTranscriptionCarriesNoPrompt() throws {
        // Prototype finding: on noise the transcriber returned the prompt itself as the
        // user's words. No prompt is ever sent.
        let data = try RealtimeClientEvent.sessionUpdate(RealtimeSessionConfig(instructions: "x")).jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"prompt\""))
    }

    func testInputAudioAppendEncodesBase64() throws {
        try assertJSON(
            RealtimeClientEvent.inputAudioAppend(Data([0x01, 0x02, 0xFF])),
            #"{ "type": "input_audio_buffer.append", "audio": "AQL/" }"#
        )
    }

    func testResponseCreate() throws {
        try assertJSON(RealtimeClientEvent.responseCreate, #"{ "type": "response.create" }"#)
    }

    func testResponseCancel() throws {
        try assertJSON(RealtimeClientEvent.responseCancel(responseID: nil), #"{ "type": "response.cancel" }"#)
        try assertJSON(
            RealtimeClientEvent.responseCancel(responseID: "resp_12345"),
            #"{ "type": "response.cancel", "response_id": "resp_12345" }"#
        )
    }

    func testFunctionCallOutput() throws {
        try assertJSON(
            RealtimeClientEvent.functionCallOutput(callID: "call_sHlR7iaFwQ2YQOqm", output: #"{"horoscope":"ok"}"#),
            #"""
            {
              "type": "conversation.item.create",
              "item": {
                "type": "function_call_output",
                "call_id": "call_sHlR7iaFwQ2YQOqm",
                "output": "{\"horoscope\":\"ok\"}"
              }
            }
            """#
        )
    }

    func testJSONStringMatchesJSONData() throws {
        let event = RealtimeClientEvent.responseCreate
        XCTAssertEqual(try event.jsonString(), String(decoding: try event.jsonData(), as: UTF8.self))
    }

    // MARK: - Server events

    func testDecodesSessionCreatedAndUpdated() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"session.created","event_id":"e1","session":{"type":"realtime","id":"sess_C9G5","model":"gpt-realtime-2.1"}}"#),
            .sessionCreated(sessionID: "sess_C9G5")
        )
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"session.updated","event_id":"e2","session":{"type":"realtime","id":"sess_C9G5"}}"#),
            .sessionUpdated(sessionID: "sess_C9G5")
        )
    }

    func testDecodesSpeechStartedAndStopped() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"event_id":"event_1516","type":"input_audio_buffer.speech_started","audio_start_ms":1000,"item_id":"msg_003"}"#),
            .speechStarted(itemID: "msg_003", audioStartMs: 1000)
        )
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"event_id":"event_1718","type":"input_audio_buffer.speech_stopped","audio_end_ms":2000,"item_id":"msg_003"}"#),
            .speechStopped(itemID: "msg_003", audioEndMs: 2000)
        )
    }

    func testDecodesResponseCreated() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"""
            {"type":"response.created","event_id":"event_C9G8","response":{"object":"realtime.response","id":"resp_C9G8p7","status":"in_progress","status_details":null,"output":[],"usage":null,"metadata":null}}
            """#),
            .responseCreated(responseID: "resp_C9G8p7")
        )
    }

    func testDecodesOutputAudioDeltaToBytes() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"event_id":"event_4950","type":"response.output_audio.delta","response_id":"resp_001","item_id":"msg_008","output_index":0,"content_index":0,"delta":"AQL/"}"#),
            .outputAudioDelta(responseID: "resp_001", itemID: "msg_008", audio: Data([0x01, 0x02, 0xFF]))
        )
    }

    func testOutputAudioDeltaWithBrokenBase64Throws() {
        XCTAssertThrowsError(
            try RealtimeServerEvent.decode(#"{"type":"response.output_audio.delta","response_id":"r","item_id":"i","delta":"%%%"}"#)
        )
    }

    func testDecodesOutputAudioDone() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"event_id":"event_5152","type":"response.output_audio.done","response_id":"resp_001","item_id":"msg_008","output_index":0,"content_index":0}"#),
            .outputAudioDone(responseID: "resp_001", itemID: "msg_008")
        )
    }

    func testDecodesResponseDoneWithTypedUsage() throws {
        let event = try RealtimeServerEvent.decode(#"""
        {
          "type": "response.done",
          "event_id": "event_CCXHxc",
          "response": {
            "object": "realtime.response",
            "id": "resp_CCXHw0",
            "status": "completed",
            "status_details": null,
            "output": [],
            "usage": {
              "total_tokens": 253,
              "input_tokens": 132,
              "output_tokens": 121,
              "input_token_details": {
                "text_tokens": 119,
                "audio_tokens": 13,
                "image_tokens": 0,
                "cached_tokens": 64,
                "cached_tokens_details": { "text_tokens": 64, "audio_tokens": 0, "image_tokens": 0 }
              },
              "output_token_details": { "text_tokens": 30, "audio_tokens": 91 }
            },
            "metadata": null
          }
        }
        """#)
        let expected = RealtimeResponseDone(
            responseID: "resp_CCXHw0",
            status: "completed",
            usage: RealtimeUsage(
                totalTokens: 253,
                inputTokens: 132,
                outputTokens: 121,
                inputTokenDetails: .init(
                    textTokens: 119,
                    audioTokens: 13,
                    imageTokens: 0,
                    cachedTokens: 64,
                    cachedTokensDetails: .init(textTokens: 64, audioTokens: 0, imageTokens: 0)
                ),
                outputTokenDetails: .init(textTokens: 30, audioTokens: 91)
            )
        )
        XCTAssertEqual(event, .responseDone(expected))
    }

    func testDecodesCancelledResponseDoneWithoutUsage() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"response.done","response":{"id":"resp_9","status":"cancelled","usage":null}}"#),
            .responseDone(RealtimeResponseDone(responseID: "resp_9", status: "cancelled", usage: nil))
        )
    }

    func testDecodesFunctionCallArgumentsDone() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"""
            {"event_id":"event_5556","type":"response.function_call_arguments.done","response_id":"resp_002","item_id":"fc_001","output_index":0,"call_id":"call_001","name":"get_weather","arguments":"{\"location\": \"San Francisco\"}"}
            """#),
            .functionCallArgumentsDone(RealtimeFunctionCall(
                callID: "call_001",
                name: "get_weather",
                arguments: #"{"location": "San Francisco"}"#,
                responseID: "resp_002",
                itemID: "fc_001"
            ))
        )
    }

    func testDecodesInputTranscriptionCompletedWithTokenUsage() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"""
            {"type":"conversation.item.input_audio_transcription.completed","event_id":"event_CCXGR","item_id":"item_CCXGQ4","content_index":0,"transcript":"Hey, can you hear me?","usage":{"type":"tokens","total_tokens":22,"input_tokens":13,"input_token_details":{"text_tokens":0,"audio_tokens":13},"output_tokens":9}}
            """#),
            .inputTranscriptionCompleted(
                itemID: "item_CCXGQ4",
                transcript: "Hey, can you hear me?",
                usage: .tokens(inputTokens: 13, outputTokens: 9, totalTokens: 22, inputAudioTokens: 13)
            )
        )
    }

    func testDecodesInputTranscriptionCompletedWithDurationUsage() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","content_index":0,"transcript":"hi","usage":{"type":"duration","seconds":2.5}}"#),
            .inputTranscriptionCompleted(itemID: "i", transcript: "hi", usage: .duration(seconds: 2.5))
        )
    }

    func testDecodesError() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"""
            {"event_id":"event_890","type":"error","error":{"type":"invalid_request_error","code":"invalid_event","message":"The 'type' field is missing.","param":null,"event_id":"event_567"}}
            """#),
            .error(RealtimeError(
                type: "invalid_request_error",
                code: "invalid_event",
                message: "The 'type' field is missing.",
                param: nil,
                clientEventID: "event_567"
            ))
        )
    }

    func testUnknownTypeDecodesToUnknownAndNeverThrows() throws {
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"rate_limits.updated","event_id":"e","rate_limits":[]}"#),
            .unknown(type: "rate_limits.updated")
        )
        XCTAssertEqual(
            try RealtimeServerEvent.decode(#"{"type":"some.future.event","whatever":{"nested":true}}"#),
            .unknown(type: "some.future.event")
        )
    }

    func testMalformedMessagesThrow() {
        XCTAssertThrowsError(try RealtimeServerEvent.decode("not json"))
        XCTAssertThrowsError(try RealtimeServerEvent.decode(#"{"event_id":"no type"}"#))
        XCTAssertThrowsError(try RealtimeServerEvent.decode(#"{"type":"response.created"}"#))
    }

    // MARK: - Fatal errors

    func testErrorFatality() {
        func error(type: String, code: String?, clientEventID: String? = nil) -> RealtimeError {
            RealtimeError(type: type, code: code, message: "m", param: nil, clientEventID: clientEventID)
        }
        XCTAssertTrue(error(type: "server_error", code: nil).isFatal)
        XCTAssertTrue(error(type: "invalid_request_error", code: "invalid_api_key").isFatal)
        XCTAssertTrue(error(type: "invalid_request_error", code: "insufficient_quota").isFatal)
        XCTAssertTrue(error(type: "invalid_request_error", code: "session_expired").isFatal)
        // A rejected command (say, response.cancel with nothing to cancel) leaves the session open.
        XCTAssertFalse(error(type: "invalid_request_error", code: "invalid_event", clientEventID: "e1").isFatal)
        XCTAssertFalse(error(type: "invalid_request_error", code: nil).isFatal)
    }

    // MARK: - Helpers

    private func assertJSON(
        _ event: RealtimeClientEvent,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try JSONSerialization.jsonObject(with: event.jsonData())
        let wanted = try JSONSerialization.jsonObject(with: Data(expected.utf8))
        XCTAssertEqual(actual as? NSDictionary, wanted as? NSDictionary, file: file, line: line)
    }
}
