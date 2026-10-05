import XCTest
@testable import Live

final class RealtimeResponseSequencerTests: XCTestCase {

    private func call(_ id: String, response: String = "resp_1") -> RealtimeFunctionCall {
        RealtimeFunctionCall(callID: id, name: "lookup", arguments: "{}", responseID: response, itemID: "fc_\(id)")
    }

    private func done(_ id: String, status: String = "completed") -> RealtimeServerEvent {
        .responseDone(RealtimeResponseDone(responseID: id, status: status, usage: nil))
    }

    private func sent(_ outputs: [RealtimeResponseSequencer.Output]) -> [RealtimeClientEvent] {
        outputs.compactMap { if case .send(let event) = $0 { return event } else { return nil } }
    }

    private func responseCreates(_ outputs: [RealtimeResponseSequencer.Output]) -> Int {
        sent(outputs).filter { $0 == .responseCreate }.count
    }

    func testArgumentsDoneAsksForTheTool() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        XCTAssertEqual(sequencer.handle(.functionCallArgumentsDone(call("c1"))), [.runTool(call("c1"))])
    }

    func testOutputBeforeResponseDoneWaitsThenGoesOutAsItemThenResponseCreate() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))

        // The response that asked for the tool is still in flight: nothing may go out yet.
        XCTAssertEqual(sequencer.toolFinished(callID: "c1", output: "42"), [])
        XCTAssertTrue(sequencer.isResponseInFlight)

        XCTAssertEqual(
            sequencer.handle(done("resp_1")),
            [.send(.functionCallOutput(callID: "c1", output: "42")), .send(.responseCreate)]
        )
    }

    func testOutputAfterResponseDoneGoesOutAtOnce() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))
        XCTAssertEqual(sequencer.handle(done("resp_1")), [])
        XCTAssertFalse(sequencer.isResponseInFlight)

        XCTAssertEqual(
            sequencer.toolFinished(callID: "c1", output: "42"),
            [.send(.functionCallOutput(callID: "c1", output: "42")), .send(.responseCreate)]
        )
        XCTAssertTrue(sequencer.isResponseInFlight, "a requested response counts as in flight")
    }

    func testNeverTwoResponsesInFlight() {
        var sequencer = RealtimeResponseSequencer()
        var creates = 0

        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1", response: "resp_1")))
        creates += responseCreates(sequencer.handle(done("resp_1")))
        creates += responseCreates(sequencer.toolFinished(callID: "c1", output: "a"))
        XCTAssertEqual(creates, 1)

        // Our response.create is requested but not yet created. The server's VAD answers
        // first with its own response, which calls another tool.
        _ = sequencer.handle(.responseCreated(responseID: "resp_vad"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c2", response: "resp_vad")))
        XCTAssertEqual(responseCreates(sequencer.toolFinished(callID: "c2", output: "b")), 0)
        creates += responseCreates(sequencer.handle(done("resp_vad")))
        XCTAssertEqual(creates, 2, "the second response.create waits for the first response to finish")

        // Still requested and not created: a third output must not ask again.
        _ = sequencer.handle(.functionCallArgumentsDone(call("c3", response: "resp_vad")))
        XCTAssertEqual(responseCreates(sequencer.toolFinished(callID: "c3", output: "c")), 0)
    }

    func testServerCreatedResponseHoldsTheOutputUntilItIsDone() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))
        _ = sequencer.handle(done("resp_1"))

        // The user speaks again before the tool ends; VAD creates a response.
        _ = sequencer.handle(.responseCreated(responseID: "resp_2"))
        XCTAssertEqual(sequencer.toolFinished(callID: "c1", output: "42"), [])
        XCTAssertEqual(
            sequencer.handle(done("resp_2")),
            [.send(.functionCallOutput(callID: "c1", output: "42")), .send(.responseCreate)]
        )
    }

    func testTwoCallsInOneResponseShareOneResponseCreate() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c2")))
        _ = sequencer.handle(done("resp_1"))

        XCTAssertEqual(
            sequencer.toolFinished(callID: "c1", output: "a"),
            [.send(.functionCallOutput(callID: "c1", output: "a"))]
        )
        XCTAssertEqual(
            sequencer.toolFinished(callID: "c2", output: "b"),
            [.send(.functionCallOutput(callID: "c2", output: "b")), .send(.responseCreate)]
        )
    }

    func testCancelledResponseDropsItsCallsAndTheirLateOutputs() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))
        XCTAssertEqual(sequencer.handle(done("resp_1", status: "cancelled")), [])
        XCTAssertEqual(sequencer.toolFinished(callID: "c1", output: "late"), [])
        XCTAssertFalse(sequencer.isResponseInFlight)
    }

    func testUnknownCallIDIsIgnored() {
        var sequencer = RealtimeResponseSequencer()
        XCTAssertEqual(sequencer.toolFinished(callID: "nobody", output: "x"), [])
    }

    func testResetForgetsEverything() {
        var sequencer = RealtimeResponseSequencer()
        _ = sequencer.handle(.responseCreated(responseID: "resp_1"))
        _ = sequencer.handle(.functionCallArgumentsDone(call("c1")))
        sequencer.reset()
        XCTAssertFalse(sequencer.isResponseInFlight)
        XCTAssertFalse(sequencer.hasPendingWork)
        XCTAssertEqual(sequencer.toolFinished(callID: "c1", output: "x"), [])
    }
}
