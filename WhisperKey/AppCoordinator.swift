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

    func updateState(_ new: AppState) { state = new }

    let settings: SettingsStore
    let hotkey: HotkeyEngineRunner

    private let recorder = AudioRecorder()
    private let encoder = AudioEncoder()
    private let log = Logger(subsystem: "WhisperKey", category: "AppCoordinator")
    private var cancellables = Set<AnyCancellable>()
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
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
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
        refreshPermissions()
        guard state == .idle, permissions.allGranted else { return }
        state = .recording
        hotkey.setAppState(.recording)

        Task {
            do {
                try await recorder.start()
            } catch AudioRecorderError.microphonePermissionDenied {
                log.error("microphone permission denied")
                await MainActor.run {
                    state = .microphoneDenied
                    hotkey.setAppState(.idle)
                }
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
        guard let provider = settings.makeTranscriptionProvider() else {
            log.error("no provider configured; cannot transcribe")
            await MainActor.run {
                state = .error("Set the API key in Settings")
                hotkey.setAppState(.idle)
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
            }
        } catch {
            log.error("transcription failed: \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                state = .error(message)
                hotkey.setAppState(.idle)
            }
        }
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
