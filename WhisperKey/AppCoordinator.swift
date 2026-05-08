import AppKit
import Combine
import Foundation
import os
import HotkeyEngine
import AudioRecorder
import AudioEncoder
import TranscriptionProvider

@MainActor
final class AppCoordinator: ObservableObject {
    enum AppState: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: AppState = .idle

    private let hotkey = HotkeyEngineRunner(config: HotkeyConfig(trigger: .rightOption, mode: .tap))
    private let recorder = AudioRecorder()
    private let encoder = AudioEncoder()
    private let provider: TranscriptionProvider?
    private let log = Logger(subsystem: "WhisperKey", category: "AppCoordinator")

    init() {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            self.provider = OpenAIProvider(apiKey: key, model: .whisper1)
        } else {
            self.provider = nil
            log.error("OPENAI_API_KEY env var not set; transcription will be skipped")
        }

        hotkey.setOutputHandler { [weak self] output in
            guard let self else { return }
            Task { @MainActor in self.handle(output) }
        }

        let started = hotkey.start()
        if !started {
            log.error("CGEventTap could not be created — Accessibility permission likely missing")
            state = .error("Accessibility permission required")
        }
    }

    private func handle(_ output: HotkeyOutput) {
        switch output {
        case .recordingShouldStart:
            startRecording()
        case .recordingShouldStop:
            stopRecording()
        }
    }

    private func startRecording() {
        guard state == .idle else { return }
        state = .recording
        hotkey.setAppState(.recording)

        Task {
            do {
                try await recorder.start()
            } catch {
                log.error("recorder.start failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    state = .error("Recording failed: \(error)")
                    hotkey.setAppState(.idle)
                }
            }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        state = .transcribing
        hotkey.setAppState(.transcribing)

        Task {
            let buffer = await recorder.stop()

            guard let buffer else {
                log.info("recording discarded (under min duration)")
                await MainActor.run {
                    state = .idle
                    hotkey.setAppState(.idle)
                }
                return
            }

            await runTranscription(buffer: buffer)
        }
    }

    private func runTranscription(buffer: AudioBuffer) async {
        guard let provider else {
            log.error("no provider configured; cannot transcribe")
            await MainActor.run {
                state = .error("Set OPENAI_API_KEY and relaunch")
                hotkey.setAppState(.idle)
            }
            return
        }

        do {
            let encoded = try encoder.encode(buffer)
            let text = try await provider.transcribe(audio: encoded, language: nil)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                log.info("transcription written to clipboard, \(text.count, privacy: .public) chars")
                state = .idle
                hotkey.setAppState(.idle)
            }
        } catch {
            log.error("transcription failed: \(String(describing: error), privacy: .public)")
            await MainActor.run {
                state = .error("Transcription failed: \(error)")
                hotkey.setAppState(.idle)
            }
        }
    }
}
