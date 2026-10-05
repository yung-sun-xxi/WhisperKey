import XCTest
@testable import Live

/// Tap-mode event scripts. Time is the `at:` of each input; nothing reads a clock.
final class LiveSessionTests: XCTestCase {

    private let config = RealtimeSessionConfig(instructions: "Be brief.")
    private let chunkA = Data([0x0A, 0x0A])
    private let chunkB = Data([0x0B, 0x0B])
    private let chunkC = Data([0x0C, 0x0C])
    private let audio1 = Data([0x01, 0x00])
    private let audio2 = Data([0x02, 0x00])

    private let closeCommands: [LiveSession.Command] = [
        .stopMicrophone, .stopPlayback, .disconnect, .playStopSound, .island(.hidden),
    ]

    private func makeSession() -> LiveSession {
        LiveSession(configuration: config)
    }

    /// Opens a session and makes it ready at `readyAt`.
    private func readySession(readyAt: TimeInterval = 1) -> LiveSession {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        _ = session.handle(.socketOpened, at: 0.5)
        _ = session.handle(.server(.sessionCreated(sessionID: "s")), at: 0.6)
        _ = session.handle(.server(.sessionUpdated(sessionID: "s")), at: readyAt)
        return session
    }

    private func delta(_ data: Data) -> LiveSession.Input {
        .server(.outputAudioDelta(responseID: "resp_1", itemID: "item_1", audio: data))
    }

    private func done(_ id: String = "resp_1", status: String = "completed") -> LiveSession.Input {
        .server(.responseDone(RealtimeResponseDone(responseID: id, status: status, usage: nil)))
    }

    private func appends(_ commands: [LiveSession.Command]) -> [Data] {
        commands.compactMap {
            if case .send(.inputAudioAppend(let data)) = $0 { return data } else { return nil }
        }
    }

    // MARK: - Opening

    func testToggleFromIdleOpens() {
        var session = makeSession()
        XCTAssertFalse(session.isOn)
        XCTAssertEqual(session.handle(.toggle, at: 0), [
            .playStartSound,
            .island(.shown(state: .connecting, text: "Connecting…")),
            .connect,
            .startMicrophone,
        ])
        XCTAssertEqual(session.state, .connecting)
        XCTAssertTrue(session.isOn)
    }

    func testSocketOpenedConfiguresTheSession() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        XCTAssertEqual(session.handle(.socketOpened, at: 0.4), [.send(.sessionUpdate(config))])
        XCTAssertEqual(session.state, .connecting, "not ready until session.updated")
        XCTAssertEqual(session.handle(.server(.sessionCreated(sessionID: "s")), at: 0.5), [])
        XCTAssertEqual(session.state, .connecting)
    }

    func testChunksBeforeReadyAreBufferedAndFlushedInOrder() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkA), at: 0.1), [])
        _ = session.handle(.socketOpened, at: 0.2)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkB), at: 0.3), [])
        _ = session.handle(.server(.sessionCreated(sessionID: "s")), at: 0.4)

        let ready = session.handle(.server(.sessionUpdated(sessionID: "s")), at: 0.5)
        XCTAssertEqual(ready, [
            .island(.shown(state: .listening, text: "Listening")),
            .send(.inputAudioAppend(chunkA)),
            .send(.inputAudioAppend(chunkB)),
        ])
        XCTAssertEqual(session.state, .listening)

        XCTAssertEqual(session.handle(.microphoneChunk(chunkC), at: 0.6), [.send(.inputAudioAppend(chunkC))])

        // The buffer was emptied by the flush: a second session.updated sends nothing again.
        XCTAssertEqual(appends(session.handle(.server(.sessionUpdated(sessionID: "s")), at: 0.7)), [])
    }

    func testBufferIsDroppedWhenClosedBeforeReady() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        _ = session.handle(.microphoneChunk(chunkA), at: 0.1)
        _ = session.handle(.toggle, at: 0.2)
        _ = session.handle(.toggle, at: 1)
        _ = session.handle(.socketOpened, at: 1.1)
        XCTAssertEqual(appends(session.handle(.server(.sessionUpdated(sessionID: "s")), at: 1.2)), [])
    }

    // MARK: - Question and answer

    func testQuestionResponseAudioPlaybackFinished() {
        var session = readySession()

        XCTAssertEqual(session.handle(.server(.speechStarted(itemID: "m", audioStartMs: 100)), at: 2), [])
        XCTAssertEqual(session.handle(.server(.speechStopped(itemID: "m", audioEndMs: 900)), at: 3), [])
        XCTAssertEqual(session.state, .listening)

        XCTAssertEqual(
            session.handle(.server(.responseCreated(responseID: "resp_1")), at: 3.2),
            [.island(.shown(state: .thinking, text: "Thinking…"))]
        )
        XCTAssertEqual(session.state, .thinking)

        XCTAssertEqual(session.handle(delta(audio1), at: 4), [
            .island(.shown(state: .speaking, text: "Speaking")),
            .playAudio(audio1),
        ])
        XCTAssertEqual(session.state, .speaking)
        XCTAssertEqual(session.handle(delta(audio2), at: 4.1), [.playAudio(audio2)])

        XCTAssertEqual(session.handle(.server(.outputAudioDone(responseID: "resp_1", itemID: "item_1")), at: 4.2), [])
        XCTAssertEqual(session.handle(done(), at: 4.3), [])
        XCTAssertEqual(session.state, .speaking, "the answer is still playing")

        XCTAssertEqual(
            session.handle(.playbackFinished, at: 6),
            [.island(.shown(state: .listening, text: "Listening"))]
        )
        XCTAssertEqual(session.state, .listening)
        XCTAssertTrue(session.isOn)
    }

    func testPlaybackDrainedBeforeResponseDoneListensAtDone() {
        var session = readySession()
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        _ = session.handle(delta(audio1), at: 3)
        // The player ran dry between deltas; the response is not over.
        XCTAssertEqual(session.handle(.playbackFinished, at: 3.5), [])
        XCTAssertEqual(session.state, .speaking)
        // More audio arrives and is played; then the player drains again before done.
        XCTAssertEqual(session.handle(delta(audio2), at: 3.6), [.playAudio(audio2)])
        XCTAssertEqual(session.handle(done(), at: 3.8), [])
        XCTAssertEqual(session.state, .speaking)
        _ = session.handle(.playbackFinished, at: 4)
        XCTAssertEqual(session.state, .listening)
    }

    func testPlaybackAlreadyDrainedWhenResponseDoneListensAtOnce() {
        var session = readySession()
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        _ = session.handle(delta(audio1), at: 3)
        _ = session.handle(.playbackFinished, at: 3.5)
        XCTAssertEqual(session.handle(done(), at: 4), [.island(.shown(state: .listening, text: "Listening"))])
        XCTAssertEqual(session.state, .listening)
    }

    func testResponseWithoutAudioReturnsToListeningAtDone() {
        var session = readySession()
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        XCTAssertEqual(session.handle(done(), at: 3), [.island(.shown(state: .listening, text: "Listening"))])
        XCTAssertEqual(session.state, .listening)
    }

    // MARK: - Half duplex

    func testMicrophoneIsNotSentFromResponseCreatedUntilPlaybackFinished() {
        var session = readySession()
        XCTAssertEqual(appends(session.handle(.microphoneChunk(chunkA), at: 2)), [chunkA])

        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 3)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkB), at: 3.1), [], "thinking: not sent")

        _ = session.handle(delta(audio1), at: 4)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkB), at: 4.1), [], "speaking: not sent")

        _ = session.handle(done(), at: 4.5)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkB), at: 4.6), [], "still playing: not sent")

        _ = session.handle(.playbackFinished, at: 5)
        XCTAssertEqual(appends(session.handle(.microphoneChunk(chunkC), at: 5.1)), [chunkC])
    }

    // MARK: - Idle rule

    func testIdleClosesThirtySecondsAfterReadyWhenNoAnswerYet() {
        var session = readySession(readyAt: 1)
        XCTAssertEqual(session.handle(.tick, at: 30.9), [])
        XCTAssertTrue(session.isOn)
        XCTAssertEqual(session.handle(.tick, at: 31), closeCommands)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isOn)
    }

    func testIdleCountsFromTheEndOfTheLastAnswer() {
        var session = readySession(readyAt: 1)
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 10)
        _ = session.handle(delta(audio1), at: 11)
        _ = session.handle(done(), at: 12)
        _ = session.handle(.playbackFinished, at: 20)

        XCTAssertEqual(session.handle(.tick, at: 31), [], "30 s after ready, but an answer ended at 20")
        XCTAssertEqual(session.handle(.tick, at: 49.9), [])
        XCTAssertEqual(session.handle(.tick, at: 50), closeCommands)
    }

    func testMicrophoneAudioAndTranscriptsDoNotResetIdle() {
        var session = readySession(readyAt: 0)
        _ = session.handle(.microphoneChunk(chunkA), at: 10)
        _ = session.handle(
            .server(.inputTranscriptionCompleted(itemID: "m", transcript: "hm", usage: nil)),
            at: 26
        )
        _ = session.handle(.microphoneChunk(chunkB), at: 29)
        XCTAssertEqual(session.handle(.tick, at: 30), closeCommands)
    }

    func testSpeechPausesIdleAndItsEndRestartsIt() {
        // A question being spoken is a question: speech_started pauses the window, and
        // speech_stopped with no response after it restarts the window from that moment.
        var session = readySession(readyAt: 0)
        _ = session.handle(.server(.speechStarted(itemID: "m", audioStartMs: 29_000)), at: 29)
        XCTAssertEqual(session.handle(.tick, at: 31), [], "speaking past the 30 s mark does not close")
        XCTAssertTrue(session.isOn)

        _ = session.handle(.server(.speechStopped(itemID: "m", audioEndMs: 32_000)), at: 32)
        XCTAssertEqual(session.handle(.tick, at: 61.9), [])
        XCTAssertEqual(session.handle(.tick, at: 62), closeCommands)
    }

    func testSpeechThenResponseStillCountsFromTheEndOfTheAnswer() {
        var session = readySession(readyAt: 0)
        _ = session.handle(.server(.speechStarted(itemID: "m", audioStartMs: 0)), at: 10)
        _ = session.handle(.server(.speechStopped(itemID: "m", audioEndMs: 0)), at: 12)
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 12.5)
        _ = session.handle(delta(audio1), at: 13)
        _ = session.handle(done(), at: 14)
        _ = session.handle(.playbackFinished, at: 20)
        XCTAssertEqual(session.handle(.tick, at: 49.9), [], "not 30 s after speech stopped at 12")
        XCTAssertEqual(session.handle(.tick, at: 50), closeCommands)
    }

    func testNoIdleCloseWhileThinkingOrSpeaking() {
        var session = readySession(readyAt: 0)
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 5)
        XCTAssertEqual(session.handle(.tick, at: 40), [])
        _ = session.handle(delta(audio1), at: 41)
        XCTAssertEqual(session.handle(.tick, at: 100), [])
        XCTAssertEqual(session.state, .speaking)
    }

    func testNoIdleCloseWhileConnecting() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        XCTAssertEqual(session.handle(.tick, at: 100), [])
        XCTAssertEqual(session.state, .connecting)
    }

    // MARK: - Closing

    func testToggleWhileOpenCloses() {
        for open in [LiveSession.State.connecting, .listening, .thinking, .speaking] {
            var session = makeSession()
            _ = session.handle(.toggle, at: 0)
            if open != .connecting {
                _ = session.handle(.socketOpened, at: 0.1)
                _ = session.handle(.server(.sessionUpdated(sessionID: "s")), at: 0.2)
            }
            if open == .thinking || open == .speaking {
                _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 1)
            }
            if open == .speaking {
                _ = session.handle(delta(audio1), at: 2)
            }
            XCTAssertEqual(session.state, open)

            XCTAssertEqual(session.handle(.toggle, at: 3), closeCommands, "closing from \(open)")
            XCTAssertEqual(session.state, .idle)
            XCTAssertFalse(session.isOn)
        }
    }

    func testEventsAfterCloseAreIgnored() {
        var session = readySession()
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        _ = session.handle(.toggle, at: 3)
        XCTAssertEqual(session.handle(delta(audio1), at: 3.1), [])
        XCTAssertEqual(session.handle(.microphoneChunk(chunkA), at: 3.2), [])
        XCTAssertEqual(session.handle(.socketClosed(reason: "Connection closed"), at: 3.3), [])
        XCTAssertEqual(session.handle(.playbackFinished, at: 3.4), [])
        XCTAssertEqual(session.handle(.tick, at: 100), [])
        XCTAssertEqual(session.state, .idle)
    }

    func testToggleAfterCloseOpensAFreshSession() {
        var session = readySession()
        _ = session.handle(.toggle, at: 5)
        XCTAssertEqual(session.handle(.toggle, at: 6).first, .playStartSound)
        XCTAssertEqual(session.state, .connecting)
    }

    // MARK: - Errors

    func testSocketClosedWhileOpenStopsEverythingWithTheReason() {
        var session = readySession()
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        _ = session.handle(delta(audio1), at: 3)

        let message = "OpenAI rejected the API key"
        XCTAssertEqual(session.handle(.socketClosed(reason: message), at: 4), [
            .stopMicrophone,
            .stopPlayback,
            .disconnect,
            .island(.shown(state: .error(message), text: message)),
            .reportError(message),
        ])
        XCTAssertEqual(session.state, .error(message))
        XCTAssertFalse(session.isOn)

        // Nothing is spoken after an error.
        XCTAssertEqual(session.handle(delta(audio2), at: 4.1), [])
    }

    func testFailureWhileConnectingIsAnError() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        let commands = session.handle(.socketClosed(reason: "OpenAI rejected the API key"), at: 0.3)
        XCTAssertTrue(commands.contains(.reportError("OpenAI rejected the API key")))
        XCTAssertEqual(session.state, .error("OpenAI rejected the API key"))
    }

    func testFatalServerErrorStopsLive() {
        var session = readySession()
        let error = RealtimeError(type: "server_error", code: nil, message: "Boom", param: nil, clientEventID: nil)
        let commands = session.handle(.server(.error(error)), at: 2)
        XCTAssertEqual(commands, [
            .stopMicrophone,
            .stopPlayback,
            .disconnect,
            .island(.shown(state: .error("Boom"), text: "Boom")),
            .reportError("Boom"),
        ])
        XCTAssertEqual(session.state, .error("Boom"))
    }

    func testRecoverableServerErrorWhileOpenIsIgnored() {
        var session = readySession()
        let error = RealtimeError(
            type: "invalid_request_error",
            code: "response_cancel_not_active",
            message: "no active response",
            param: nil,
            clientEventID: "e1"
        )
        XCTAssertEqual(session.handle(.server(.error(error)), at: 2), [])
        XCTAssertEqual(session.state, .listening)
    }

    func testAnyServerErrorWhileConnectingIsFatal() {
        // A rejected session.update leaves a session that cannot work.
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        _ = session.handle(.socketOpened, at: 0.1)
        let error = RealtimeError(type: "invalid_request_error", code: "invalid_value", message: "Bad voice", param: "session.audio.output.voice", clientEventID: nil)
        XCTAssertTrue(session.handle(.server(.error(error)), at: 0.2).contains(.reportError("Bad voice")))
        XCTAssertEqual(session.state, .error("Bad voice"))
    }

    func testToggleFromErrorOpensAgain() {
        var session = makeSession()
        _ = session.handle(.toggle, at: 0)
        _ = session.handle(.socketClosed(reason: "Network down"), at: 1)
        XCTAssertEqual(session.handle(.toggle, at: 2), [
            .playStartSound,
            .island(.shown(state: .connecting, text: "Connecting…")),
            .connect,
            .startMicrophone,
        ])
        XCTAssertTrue(session.isOn)
    }

    // MARK: - Tools

    func testFunctionCallRunsTheToolAndKeepsThinking() {
        var session = readySession()
        let call = RealtimeFunctionCall(callID: "c1", name: "lookup", arguments: "{}", responseID: "resp_1", itemID: "fc_1")
        _ = session.handle(.server(.responseCreated(responseID: "resp_1")), at: 2)
        XCTAssertEqual(session.handle(.server(.functionCallArgumentsDone(call)), at: 2.5), [.runTool(call)])
        XCTAssertEqual(session.handle(done(), at: 3), [])
        XCTAssertEqual(session.state, .thinking, "a tool is running; this is not the end of the answer")

        XCTAssertEqual(session.handle(.toolFinished(callID: "c1", output: "42"), at: 4), [
            .send(.functionCallOutput(callID: "c1", output: "42")),
            .send(.responseCreate),
        ])
        XCTAssertEqual(session.state, .thinking)
        XCTAssertEqual(session.handle(.microphoneChunk(chunkA), at: 4.1), [], "still half duplex")

        _ = session.handle(.server(.responseCreated(responseID: "resp_2")), at: 4.2)
        _ = session.handle(delta(audio1), at: 4.5)
        XCTAssertEqual(session.state, .speaking)
    }
}
