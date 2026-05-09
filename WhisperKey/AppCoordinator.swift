import AppKit
import Combine
import Foundation
import os
import HotkeyEngine
import AudioRecorder
import AudioEncoder
import SettingsStore
import TranscriptionProvider

@MainActor
final class AppCoordinator: ObservableObject {
    enum AppState: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
        case microphoneDenied
        case accessibilityDenied
    }

    @Published private(set) var state: AppState = .idle
    @Published var permissions = PermissionState.current()
    @Published private(set) var recordingElapsed: TimeInterval = 0

    func updateState(_ new: AppState) { state = new }

    let settings: SettingsStore
    let hotkey: HotkeyEngineRunner

    private let recorder = AudioRecorder()
    private let encoder = AudioEncoder()
    private let sounds = SoundPlayer()
    private let log = Logger(subsystem: "WhisperKey", category: "AppCoordinator")
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartedAt: Date?
    private var recordingTimerTask: Task<Void, Never>?
    var hotkeyStarted = false
    var permissionPollTask: Task<Void, Never>?
    var workspaceActivationObserver: NSObjectProtocol?
    var onboardingWindowController: OnboardingWindowController?

    init(settings: SettingsStore? = nil) {
        let resolvedSettings = settings ?? SettingsStore()
        self.settings = resolvedSettings
        self.hotkey = HotkeyEngineRunner(config: resolvedSettings.hotkeyConfig)

        hotkey.setOutputHandler { [weak self] output in
            guard let self else { return }
            Task { @MainActor in self.handle(output) }
        }

        observeSettings()
        observeWorkspaceActivation()
        startPermissionPolling()

        onboardingWindowController = OnboardingWindowController(coordinator: self)
        refreshPermissions(forceOnboarding: true)
    }

    deinit {
        permissionPollTask?.cancel()
        recordingTimerTask?.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
    }

    var recordingTimerText: String {
        let total = Int(recordingElapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
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
        refreshPermissions()
        guard state == .idle, permissions.allGranted else { return }
        state = .recording
        hotkey.setAppState(.recording)
        startRecordingTimer()

        Task {
            do {
                try await recorder.start()
                playSound(.start)
            } catch AudioRecorderError.microphonePermissionDenied {
                log.error("microphone permission denied")
                await MainActor.run {
                    stopRecordingTimer()
                    state = .microphoneDenied
                    hotkey.setAppState(.idle)
                    playSound(.error)
                }
            } catch {
                log.error("recorder.start failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    stopRecordingTimer()
                    state = .error("Recording failed: \(error)")
                    hotkey.setAppState(.idle)
                    playSound(.error)
                }
            }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        state = .transcribing
        hotkey.setAppState(.transcribing)
        stopRecordingTimer()
        playSound(.stop)

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
        guard let provider = settings.makeTranscriptionProvider() else {
            log.error("no provider configured; cannot transcribe")
            await MainActor.run {
                state = .error("Set the API key in Settings")
                hotkey.setAppState(.idle)
                playSound(.error)
            }
            return
        }

        let language = settings.language.isoCode

        do {
            let encoded = try encoder.encode(buffer)
            let text = try await provider.transcribe(audio: encoded, language: language)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                log.info("transcription written to clipboard, \(text.count, privacy: .public) chars")
                state = .idle
                hotkey.setAppState(.idle)
                playSound(.done)
            }
        } catch {
            log.error("transcription failed: \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                state = .error(message)
                hotkey.setAppState(.idle)
                playSound(.error)
            }
        }
    }

    private func playSound(_ event: SoundPlayer.Event) {
        guard settings.soundEffectsEnabled else { return }
        sounds.play(event)
    }

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingStartedAt = Date()
        recordingElapsed = 0
        recordingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, let started = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingStartedAt = nil
        recordingElapsed = 0
    }

    private func observeSettings() {
        settings.$triggerKey
            .combineLatest(settings.$triggerMode)
            .map { trigger, mode in HotkeyConfig(trigger: trigger, mode: mode) }
            .removeDuplicates()
            .sink { [weak self] config in
                self?.hotkey.setConfig(config)
            }
            .store(in: &cancellables)
    }
}
