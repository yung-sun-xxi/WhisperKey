import Foundation

/// Function-call bookkeeping for one Realtime session. Pure: it is told what the server said
/// and when a tool finished, and answers with what to do.
///
/// The sequence, per the Realtime conversations guide: the model finishes a call
/// (`response.function_call_arguments.done`) → the app runs the tool → the result goes back as
/// `conversation.item.create { type: function_call_output }` → `response.create` so the model
/// speaks it. The API rejects a second response while one is active, so:
///
/// - Nothing goes out while a response is in flight. "In flight" is from our `response.create`
///   (or the server's own VAD response) until its `response.done`. Outputs that arrive in that
///   window are queued and sent after `response.done`.
/// - `response.create` waits until every call still running has its output, so one response
///   answers them all.
/// - A cancelled or failed response forgets its calls; their late outputs are dropped.
///
/// A tool starts as soon as its arguments are complete, before `response.done`, to save time.
public struct RealtimeResponseSequencer: Equatable, Sendable {
    public enum Output: Equatable, Sendable {
        case runTool(RealtimeFunctionCall)
        case send(RealtimeClientEvent)
    }

    private struct ReadyOutput: Equatable, Sendable {
        let callID: String
        let output: String
    }

    /// call_id → the response that asked for it.
    private var runningCalls: [String: String?] = [:]
    private var readyOutputs: [ReadyOutput] = []
    private var responseActive = false
    private var responseRequested = false
    private var wantsResponse = false

    public init() {}

    /// True from a `response.create` we sent, or a `response.created` from the server, until
    /// that response's `response.done`.
    public var isResponseInFlight: Bool { responseActive || responseRequested }

    /// A tool is running, an output waits to be sent, or a response must still be asked for.
    public var hasPendingWork: Bool { !runningCalls.isEmpty || !readyOutputs.isEmpty || wantsResponse }

    public mutating func handle(_ event: RealtimeServerEvent) -> [Output] {
        switch event {
        case .responseCreated:
            responseRequested = false
            responseActive = true
            return []

        case .functionCallArgumentsDone(let call):
            guard runningCalls[call.callID] == nil else { return [] }
            runningCalls[call.callID] = call.responseID
            return [.runTool(call)]

        case .responseDone(let done):
            responseActive = false
            if done.status == "cancelled" || done.status == "failed" {
                let dropped = Set(runningCalls.filter { $0.value == done.responseID }.keys)
                for callID in dropped { runningCalls[callID] = nil }
            }
            return flush()

        default:
            return []
        }
    }

    public mutating func toolFinished(callID: String, output: String) -> [Output] {
        guard runningCalls.removeValue(forKey: callID) != nil else { return [] }
        readyOutputs.append(ReadyOutput(callID: callID, output: output))
        return flush()
    }

    public mutating func reset() {
        self = RealtimeResponseSequencer()
    }

    private mutating func flush() -> [Output] {
        guard !isResponseInFlight else { return [] }
        var outputs: [Output] = readyOutputs.map {
            .send(.functionCallOutput(callID: $0.callID, output: $0.output))
        }
        if !readyOutputs.isEmpty { wantsResponse = true }
        readyOutputs.removeAll()
        if wantsResponse && runningCalls.isEmpty {
            wantsResponse = false
            responseRequested = true
            outputs.append(.send(.responseCreate))
        }
        return outputs
    }
}
