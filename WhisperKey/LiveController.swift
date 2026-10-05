import AppKit
import AudioRecorder
import Foundation
import HotkeyEngine
import Live
import os
import SettingsStore

/// Runs Live: feeds `LiveSession` its inputs and carries out the commands it returns.
///
/// Every decision — when to connect, what to send, when to listen, when to close — is the
/// session's, and is unit-tested there. This class only executes, so it holds no rules of
/// its own beyond plumbing: which socket, microphone stream or player an event belongs to.
///
/// Live is OpenAI-only, so it always uses the OpenAI key from the settings whatever the
/// dictation provider is; `LiveAvailability.swift` says why the provider choice does not
/// apply.
@MainActor
final class LiveController {
    private let settings: SettingsStore
    /// The app's single microphone owner, shared with dictation.
    private let recorder: AudioRecorder
    private let hotkey: HotkeyEngineRunner
    private let playSound: (SoundPlayer.Event) -> Void
    private let showError: (String) -> Void

    private var session = LiveSession(configuration: RealtimeSessionConfig(instructions: LiveBasePrompt.text))
    private let player = LiveAudioPlayer()
    /// Created on the first island command, so a launch with Live off builds no window.
    private var islandWindow: LiveIslandWindow?
    private let log = Logger(subsystem: "WhisperKey", category: "Live")

    /// Inputs that arrived while a batch of commands was executing. A command may produce an
    /// input synchronously (a missing key, a tool with no implementation); handling it there
    /// would interleave two batches, so it waits for the current batch to finish.
    private var pendingInputs: [LiveSession.Input] = []
    private var isHandling = false

    // Socket. `connectionID` tags everything a socket produces, so a late close or message
    // from a socket already let go of never reaches a newer session.
    private var connectionID = 0
    private var transport: RealtimeTransport?
    private var receiveTask: Task<Void, Never>?
    private var outgoing: AsyncStream<String>.Continuation?
    private var sendTask: Task<Void, Never>?

    // Microphone, tagged the same way.
    private var microphoneID = 0
    private var microphoneChunks: AsyncStream<Data>.Continuation?
    private var microphoneTask: Task<Void, Never>?

    private var tickTask: Task<Void, Never>?
    private var islandHideTask: Task<Void, Never>?
    private var reportedLiveActive = false

    /// How long the red island stays after an error before it goes away by itself.
    private static let errorIslandDuration: Duration = .seconds(3)

    init(
        settings: SettingsStore,
        recorder: AudioRecorder,
        hotkey: HotkeyEngineRunner,
        playSound: @escaping (SoundPlayer.Event) -> Void,
        showError: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.recorder = recorder
        self.hotkey = hotkey
        self.playSound = playSound
        self.showError = showError

        player.onAllPlayed = { [weak self] in
            self?.feed(.playbackFinished)
        }
        player.onFailure = { [weak self] message in
            // LiveSession has no playback-failure input; a failure that ends the session is
            // what `socketClosed` already means to it.
            self?.feed(.socketClosed(reason: message))
        }
    }

    /// The chord: opens Live when it is closed, closes it when it is open.
    func toggle() {
        feed(.toggle)
    }

    /// Live stopped being available (setting off, key removed, trigger changed): close an open
    /// session and take down a lingering error island.
    func shutDown() {
        if session.isOn {
            log.info("Live closed: no longer available")
            feed(.toggle)
        } else {
            islandHideTask?.cancel()
            islandHideTask = nil
            dismissIsland()
        }
    }

    // MARK: - The session loop

    private func feed(_ input: LiveSession.Input) {
        pendingInputs.append(input)
        guard !isHandling else { return }
        isHandling = true
        defer { isHandling = false }

        while !pendingInputs.isEmpty {
            let next = pendingInputs.removeFirst()
            let before = session.state
            let commands = session.handle(next, at: Self.now())
            if session.state != before {
                log.info("Live state \(Self.describe(before), privacy: .public) -> \(Self.describe(self.session.state), privacy: .public)")
            }
            for command in commands {
                execute(command)
            }
            syncWithSessionOn()
        }
    }

    /// One clock for every input: monotonic, unaffected by wall-clock changes.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Mutual exclusion with dictation, and the idle clock, both follow `isOn`.
    private func syncWithSessionOn() {
        let isOn = session.isOn
        if isOn != reportedLiveActive {
            reportedLiveActive = isOn
            hotkey.setLiveActive(isOn)
        }
        if isOn, tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.feed(.tick)
                }
            }
        } else if !isOn, let tickTask {
            tickTask.cancel()
            self.tickTask = nil
        }
    }

    private func execute(_ command: LiveSession.Command) {
        switch command {
        case .connect:
            connect()
        case .send(let event):
            send(event)
        case .startMicrophone:
            startMicrophone()
        case .stopMicrophone:
            stopMicrophone()
        case .playAudio(let audio):
            player.enqueue(audio)
        case .stopPlayback:
            player.stop()
        case .disconnect:
            disconnect()
        case .island(let island):
            showIsland(island)
        case .playStartSound:
            playSound(.start)
        case .playStopSound:
            playSound(.stop)
        case .reportError(let message):
            log.error("Live error: \(message, privacy: .public)")
            showError(message)
        case .runTool(let call):
            // No tools exist in this slice. Answering with an error output keeps the
            // function-call sequence complete, so the model can still speak.
            log.info("Live tool call \(call.name, privacy: .public) refused: no tools")
            feed(.toolFinished(callID: call.callID, output: #"{"error":"No tools are available."}"#))
        }
    }

    // MARK: - Socket

    private func connect() {
        disconnect()
        let apiKey = settings.openAIAPIKey
        guard !apiKey.isEmpty else {
            feed(.socketClosed(reason: LiveAvailability.needsOpenAIKey.message ?? "Live needs an OpenAI key"))
            return
        }

        connectionID += 1
        let id = connectionID
        let transport = RealtimeTransport(apiKey: apiKey, model: session.configuration.model)
        self.transport = transport

        // One serial sender, so audio chunks reach the socket in the order they were captured.
        let (messages, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        outgoing = continuation
        sendTask = Task { [weak self] in
            for await text in messages {
                do {
                    try await transport.send(text: text)
                } catch {
                    // The receive side reports the failure that ends the session; a send that
                    // fails on a dying socket only needs a trace.
                    self?.log.error("Live send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        log.info("Live connecting, model \(self.session.configuration.model, privacy: .public)")
        receiveTask = Task { [weak self] in
            do {
                let stream = try await transport.connect()
                guard let self, self.connectionID == id else { return }
                self.log.info("Live socket open")
                self.feed(.socketOpened)
                for try await text in stream {
                    guard self.connectionID == id else { return }
                    self.received(text)
                }
            } catch {
                guard let self, self.connectionID == id else { return }
                let reason = (error as? RealtimeTransportError)?.message ?? error.localizedDescription
                self.log.error("Live socket closed: \(reason, privacy: .public)")
                self.feed(.socketClosed(reason: reason))
            }
        }
    }

    private func received(_ text: String) {
        let event: RealtimeServerEvent
        do {
            event = try RealtimeServerEvent.decode(text)
        } catch {
            log.error("Live server event not decoded: \(String(describing: error), privacy: .public)")
            return
        }
        if case .outputAudioDelta = event {
            log.debug("Live server event \(Self.typeName(of: event), privacy: .public)")
        } else {
            log.info("Live server event \(Self.typeName(of: event), privacy: .public)")
        }
        feed(.server(event))
    }

    private func send(_ event: RealtimeClientEvent) {
        guard let outgoing else {
            log.error("Live send without a socket: \(event.type, privacy: .public)")
            return
        }
        do {
            outgoing.yield(try event.jsonString())
        } catch {
            log.error("Live event not encoded: \(event.type, privacy: .public)")
        }
    }

    private func disconnect() {
        connectionID += 1
        outgoing?.finish()
        outgoing = nil
        sendTask?.cancel()
        sendTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transport?.close()
        transport = nil
    }

    // MARK: - Microphone

    private func startMicrophone() {
        stopMicrophone()
        microphoneID += 1
        let id = microphoneID

        // The recorder calls back on its own queue and must not be held up there: the chunk
        // goes straight into a stream and is handled on the main actor.
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        microphoneChunks = continuation
        microphoneTask = Task { [weak self] in
            for await chunk in chunks {
                guard let self, self.microphoneID == id else { return }
                self.feed(.microphoneChunk(chunk))
            }
        }

        let recorder = self.recorder
        Task { [weak self] in
            do {
                try await recorder.startStreaming { @Sendable chunk in
                    continuation.yield(chunk)
                }
                // Stopped while the start was still in flight: `stopStreaming` was a no-op
                // then, so release the microphone now.
                if self?.microphoneID != id {
                    await recorder.stopStreaming()
                }
            } catch {
                guard let self, self.microphoneID == id else { return }
                let reason = Self.microphoneFailureMessage(error)
                self.log.error("Live microphone failed: \(String(describing: error), privacy: .public)")
                // LiveSession has no microphone-failure input; ending the session with a
                // reason is exactly what `socketClosed` does.
                self.feed(.socketClosed(reason: reason))
            }
        }
    }

    private func stopMicrophone() {
        guard microphoneChunks != nil else { return }
        microphoneID += 1
        microphoneChunks?.finish()
        microphoneChunks = nil
        microphoneTask?.cancel()
        microphoneTask = nil
        let recorder = self.recorder
        Task { await recorder.stopStreaming() }
    }

    private static func microphoneFailureMessage(_ error: Error) -> String {
        switch error as? AudioRecorderError {
        case .microphonePermissionDenied:
            return "Live needs microphone access"
        case .alreadyRecording:
            return "The microphone is busy"
        case .engineFailedToStart:
            return "The microphone could not start"
        case .engineStartTimedOut:
            return "The microphone did not start in time"
        case nil:
            return "The microphone could not start"
        }
    }

    // MARK: - Island

    private func showIsland(_ command: LiveIsland) {
        islandHideTask?.cancel()
        islandHideTask = nil
        guard case .shown(let state, _) = command else {
            dismissIsland()
            return
        }

        // A window of its own per session, as the toast and the quick-paste panel do. One
        // panel kept for the life of the app was ordered front and never reached the screen
        // after the displays were reconfigured (mirroring switched) while it existed.
        let window = islandWindow ?? LiveIslandWindow()
        islandWindow = window
        window.apply(command)
        log.info("Live island \(Self.describe(state), privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public) visible=\(window.isVisible, privacy: .public) activeSpace=\(window.isOnActiveSpace, privacy: .public)")

        // The red island outlives the session by a few seconds, then goes. Any later island
        // command — a new session opening — cancels this.
        if case .error = state {
            islandHideTask = Task { [weak self] in
                try? await Task.sleep(for: Self.errorIslandDuration)
                guard !Task.isCancelled, let self else { return }
                self.dismissIsland()
            }
        }
    }

    /// Takes the island off screen and lets the window go; the next session builds a new one.
    private func dismissIsland() {
        islandWindow?.hide()
        islandWindow?.close()
        islandWindow = nil
    }

    // MARK: - Logging

    private static func describe(_ state: LiveSession.State) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .error(let message): return "error(\(message))"
        }
    }

    /// The wire name, for the log. Audio and transcripts are never logged.
    private static func typeName(of event: RealtimeServerEvent) -> String {
        switch event {
        case .sessionCreated: return "session.created"
        case .sessionUpdated: return "session.updated"
        case .speechStarted: return "input_audio_buffer.speech_started"
        case .speechStopped: return "input_audio_buffer.speech_stopped"
        case .responseCreated: return "response.created"
        case .outputAudioDelta: return "response.output_audio.delta"
        case .outputAudioDone: return "response.output_audio.done"
        case .responseDone(let done): return "response.done(\(done.status ?? "-"))"
        case .functionCallArgumentsDone: return "response.function_call_arguments.done"
        case .inputTranscriptionCompleted: return "conversation.item.input_audio_transcription.completed"
        case .error(let error): return "error(\(error.type)/\(error.code ?? "-"))"
        case .unknown(let type): return type
        }
    }
}
