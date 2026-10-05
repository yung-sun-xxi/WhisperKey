import Foundation

/// What the on-screen island should show.
public enum LiveIsland: Equatable, Sendable {
    case hidden
    case shown(state: LiveSession.State, text: String)

    static func showing(_ state: LiveSession.State) -> LiveIsland {
        .shown(state: state, text: text(for: state))
    }

    static func text(for state: LiveSession.State) -> String {
        switch state {
        case .idle: return ""
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .error(let message): return message
        }
    }
}

/// The Live session state machine, tap mode. Pure value type: no clock, socket or audio.
/// Every input arrives with its time; every effect leaves as a command for the app layer.
///
///     idle ─toggle→ connecting ─session.updated→ listening ─response.created→ thinking
///       ↑                                          ↑                            │ first audio delta
///       └──── toggle / 30 s idle ─────────────────┤                            ↓
///                                                  └── playback finished ── speaking
///     any open state ─socket closed / fatal error→ error(message)
///
/// Hold mode (ticket #107) will add its own inputs (chord down/up) and turn rules beside the
/// tap-mode ones; `toggle` stays the tap-mode chord.
public struct LiveSession: Equatable, Sendable {
    /// Tap mode closes after this long without a question.
    public static let idleTimeout: TimeInterval = 30

    public enum State: Equatable, Sendable {
        case idle
        /// Socket opening, or open and waiting for `session.updated`.
        case connecting
        case listening
        /// A response exists and no audio of it has arrived yet, or a tool is running.
        case thinking
        case speaking
        case error(String)
    }

    public enum Input: Equatable, Sendable {
        /// The tap-mode chord: opens when closed, closes when open.
        case toggle
        case socketOpened
        /// The socket closed or failed without the session asking for it.
        case socketClosed(reason: String)
        case server(RealtimeServerEvent)
        /// PCM16 24 kHz mono from the microphone.
        case microphoneChunk(Data)
        /// The player has played everything it was given.
        case playbackFinished
        case toolFinished(callID: String, output: String)
        /// Drives the idle rule; the app sends it about once a second.
        case tick
    }

    public enum Command: Equatable, Sendable {
        case connect
        /// Includes configuring the session: `.send(.sessionUpdate(config))` once the socket opens.
        case send(RealtimeClientEvent)
        case startMicrophone
        case stopMicrophone
        case playAudio(Data)
        case stopPlayback
        case disconnect
        case island(LiveIsland)
        case playStartSound
        case playStopSound
        case reportError(String)
        case runTool(RealtimeFunctionCall)
    }

    public let configuration: RealtimeSessionConfig
    public let idleTimeout: TimeInterval
    public private(set) var state: State = .idle

    /// Microphone audio captured before the session is ready, in capture order.
    private var pendingChunks: [Data] = []
    /// When the idle window started: ready, or the end of the last answer. Nil while a
    /// response is being produced or played.
    private var idleSince: TimeInterval?
    /// Audio was handed to the player and it has not reported playing it all.
    private var playbackPending = false
    /// The server finished the current answer; only playback remains.
    private var answerComplete = false
    private var sequencer = RealtimeResponseSequencer()

    public init(configuration: RealtimeSessionConfig, idleTimeout: TimeInterval = LiveSession.idleTimeout) {
        self.configuration = configuration
        self.idleTimeout = idleTimeout
    }

    /// Live is "on" — for hotkey mutual exclusion — from the opening toggle until it closes.
    public var isOn: Bool {
        switch state {
        case .connecting, .listening, .thinking, .speaking: return true
        case .idle, .error: return false
        }
    }

    public mutating func handle(_ input: Input, at now: TimeInterval) -> [Command] {
        switch input {
        case .toggle:
            return isOn ? close() : open()

        case .tick:
            guard state == .listening, let idleSince, now - idleSince >= idleTimeout else { return [] }
            return close()

        case .socketOpened:
            guard state == .connecting else { return [] }
            return [.send(.sessionUpdate(configuration))]

        case .socketClosed(let reason):
            guard isOn else { return [] }
            return fail(reason)

        case .microphoneChunk(let chunk):
            // Half duplex until echo cancellation lands (ticket #108): from response.created
            // until the answer has finished playing, the microphone is not sent. On speakers
            // the model would otherwise hear its own voice and answer itself. Voice barge-in
            // is therefore impossible in this slice; the chord still closes the session.
            switch state {
            case .connecting:
                pendingChunks.append(chunk)
                return []
            case .listening:
                return [.send(.inputAudioAppend(chunk))]
            default:
                return []
            }

        case .playbackFinished:
            guard isOn else { return [] }
            playbackPending = false
            if state == .speaking && answerComplete {
                return listen(at: now)
            }
            return []

        case .toolFinished(let callID, let output):
            guard isOn else { return [] }
            return commands(sequencer.toolFinished(callID: callID, output: output))

        case .server(let event):
            guard isOn else { return [] }
            return handle(event, at: now)
        }
    }

    // MARK: - Server events

    private mutating func handle(_ event: RealtimeServerEvent, at now: TimeInterval) -> [Command] {
        if case .error(let error) = event {
            // Before ready, any error means the session could not be configured.
            guard state == .connecting || error.isFatal else { return [] }
            return fail(error.message)
        }

        if state == .connecting {
            guard case .sessionUpdated = event else { return [] }
            state = .listening
            idleSince = now
            let flushed = pendingChunks.map { Command.send(.inputAudioAppend($0)) }
            pendingChunks.removeAll()
            return [.island(.showing(.listening))] + flushed
        }

        let sequenced = commands(sequencer.handle(event))

        switch event {
        case .speechStarted:
            // A question being spoken is a question: the idle window pauses while it lasts.
            if state == .listening { idleSince = nil }
            return sequenced

        case .speechStopped:
            // If no response follows (noise, a question VAD did not answer), the window
            // restarts from the end of the speech, not from where it was paused.
            if state == .listening { idleSince = now }
            return sequenced

        case .responseCreated:
            // A question got an answer started; the window restarts when that answer ends.
            idleSince = nil
            answerComplete = false
            guard state != .thinking else { return sequenced }
            state = .thinking
            return [.island(.showing(.thinking))] + sequenced

        case .outputAudioDelta(_, _, let audio):
            guard state == .thinking || state == .speaking else { return sequenced }
            playbackPending = true
            var result: [Command] = []
            if state != .speaking {
                state = .speaking
                result.append(.island(.showing(.speaking)))
            }
            return result + [.playAudio(audio)] + sequenced

        case .responseDone:
            guard state == .thinking || state == .speaking else { return sequenced }
            if sequencer.hasPendingWork || sequencer.isResponseInFlight {
                // A tool runs or a follow-up response is coming: the answer is not over.
                return sequenced
            }
            if playbackPending {
                answerComplete = true
                return sequenced
            }
            return sequenced + listen(at: now)

        default:
            return sequenced
        }
    }

    // MARK: - Transitions

    private mutating func open() -> [Command] {
        resetSession()
        state = .connecting
        return [.playStartSound, .island(.showing(.connecting)), .connect, .startMicrophone]
    }

    private mutating func close() -> [Command] {
        resetSession()
        state = .idle
        return [.stopMicrophone, .stopPlayback, .disconnect, .playStopSound, .island(.hidden)]
    }

    /// Errors stop everything and say why on the island and in the toast. Nothing is spoken.
    private mutating func fail(_ message: String) -> [Command] {
        resetSession()
        state = .error(message)
        return [.stopMicrophone, .stopPlayback, .disconnect, .island(.showing(.error(message))), .reportError(message)]
    }

    private mutating func listen(at now: TimeInterval) -> [Command] {
        state = .listening
        idleSince = now
        answerComplete = false
        return [.island(.showing(.listening))]
    }

    private mutating func resetSession() {
        pendingChunks.removeAll()
        idleSince = nil
        playbackPending = false
        answerComplete = false
        sequencer.reset()
    }

    private func commands(_ outputs: [RealtimeResponseSequencer.Output]) -> [Command] {
        outputs.map {
            switch $0 {
            case .runTool(let call): return .runTool(call)
            case .send(let event): return .send(event)
            }
        }
    }
}
