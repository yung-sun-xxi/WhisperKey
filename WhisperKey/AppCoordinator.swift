import AppKit
import Combine
import Foundation
import os
import HotkeyEngine
import AudioRecorder
import AudioEncoder
import SettingsStore
import TranscriptionProvider
import PasteEngine
import ErrorToast
import HistoryStore
import LoginItem

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
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published var launchAtLoginError: String?

    func updateState(_ new: AppState) { state = new }

    let settings: SettingsStore
    let hotkey: HotkeyEngineRunner
    let history: HistoryStore
    private let loginItem: LoginItemController

    private let recorder = AudioRecorder()
    private let encoder = AudioEncoder()
    private let sounds = SoundPlayer()
    private let outputRouter = TranscriptionOutputRouter()
    private let toastPresenter = ToastPresenter()
    private let log = Logger(subsystem: "WhisperKey", category: "AppCoordinator")
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartedAt: Date?
    private var recordingTimerTask: Task<Void, Never>?
    private var lastTranscriptionRequest: (encoded: EncodedAudio, language: String?, audioDuration: TimeInterval)?
    var hotkeyStarted = false
    var permissionPollTask: Task<Void, Never>?
    var workspaceActivationObserver: NSObjectProtocol?
    var onboardingWindowController: OnboardingWindowController?
    var openMenuBarPopoverHandler: (() -> Void)?
    var closeMenuBarPopoverHandler: (() -> Void)?

    init(
        settings: SettingsStore? = nil,
        history: HistoryStore? = nil,
        loginItemService: LoginItemService? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        self.settings = resolvedSettings
        self.history = history ?? HistoryStore(maxEntries: resolvedSettings.historyMaxEntries)
        self.hotkey = HotkeyEngineRunner(config: resolvedSettings.hotkeyConfig)
        let resolvedLoginService = loginItemService ?? SMAppServiceLoginItem()
        self.loginItem = LoginItemController(service: resolvedLoginService)
        self.launchAtLoginEnabled = self.loginItem.isEnabled

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
        toastPresenter.dismiss(animated: false)

        Task {
            do {
                await recorder.setOnMaxDurationReached { [weak self] in
                    guard let self else { return }
                    await MainActor.run { self.stopRecording() }
                }
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
        log.info("transcription in flight; further hotkey presses will be suppressed")
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

            await transcribeNew(buffer: buffer)
        }
    }

    private func transcribeNew(buffer: AudioBuffer) async {
        let language = settings.language.isoCode
        let encoded: EncodedAudio
        do {
            encoded = try encoder.encode(buffer)
        } catch {
            log.error("audio encode failed: \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastTranscriptionRequest = nil
            self.handleTranscriptionFailure(reason: .transcription(.unknown), message: message)
            return
        }

        let audioDuration = buffer.duration
        let levels = Self.audioLevels(buffer)
        log.info("recording captured duration=\(audioDuration, privacy: .public) pcmBytes=\(buffer.samples.count, privacy: .public) sampleRate=\(buffer.sampleRate, privacy: .public) channels=\(buffer.channelCount, privacy: .public) rmsDbFS=\(levels.rmsDbFS, privacy: .public) peakDbFS=\(levels.peakDbFS, privacy: .public)")

        self.lastTranscriptionRequest = (encoded, language, audioDuration)
        await runTranscription(encoded: encoded, language: language, audioDuration: audioDuration)
    }

    private func runTranscription(encoded: EncodedAudio, language: String?, audioDuration: TimeInterval) async {
        guard let provider = settings.makeTranscriptionProvider() else {
            log.error("no provider configured; cannot transcribe")
            handleTranscriptionFailure(
                reason: .missingProvider,
                message: "Set the API key in Settings."
            )
            return
        }

        do {
            log.info("transcription request provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) mimeType=\(encoded.mimeType, privacy: .public) extension=\(encoded.fileExtension, privacy: .public) bytes=\(encoded.data.count, privacy: .public) duration=\(audioDuration, privacy: .public)")
            let text = try await provider.transcribe(audio: encoded, language: language)
            let trimmedLength = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            log.info("transcription parsed chars=\(text.count, privacy: .public) trimmedChars=\(trimmedLength, privacy: .public)")

            guard trimmedLength > 0 else {
                log.info("empty transcription result; clipboard and paste skipped provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public)")
                self.lastTranscriptionRequest = nil
                state = .idle
                hotkey.setAppState(.idle)
                playSound(.done)
                return
            }

            let outputSettings = TranscriptionOutputSettings(
                saveToClipboard: settings.saveTranscriptionToClipboard,
                autoPaste: settings.autoPasteTranscription
            )
            let output = await outputRouter.deliver(text: text, settings: outputSettings)
            log.info("transcription output saveToClipboard=\(outputSettings.saveToClipboard, privacy: .public) autoPaste=\(outputSettings.autoPaste, privacy: .public) wroteClipboard=\(output.wroteClipboard, privacy: .public) pasteDecision=\(String(describing: output.pasteDecision), privacy: .public) restoredClipboard=\(output.restoredClipboard, privacy: .public)")
            let priceEstimate = TranscriptionCostEstimator.estimate(
                providerID: settings.provider.rawValue,
                model: currentTranscriptionModelID,
                audioDurationSeconds: audioDuration
            )
            _ = history.append(
                text: text,
                providerID: settings.provider.rawValue,
                language: language,
                audioDurationSeconds: audioDuration,
                model: currentTranscriptionModelID,
                estimatedPriceAtTime: priceEstimate?.amount,
                currency: priceEstimate?.currency,
                destinationUsed: Self.destinationUsed(for: outputSettings),
                copiedToClipboard: outputSettings.saveToClipboard && output.wroteClipboard,
                autoPasted: output.pasteDecision == .paste
            )
            self.lastTranscriptionRequest = nil
            state = .idle
            hotkey.setAppState(.idle)
            playSound(.done)
        } catch let error as TranscriptionError {
            log.error("transcription failed: \(String(describing: error), privacy: .public)")
            let message = error.errorDescription ?? "Transcription failed."
            handleTranscriptionFailure(reason: .transcription(error.category), message: message)
        } catch {
            log.error("transcription failed (other): \(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            handleTranscriptionFailure(reason: .transcription(.unknown), message: message)
        }
    }

    func retryLastTranscription() {
        guard let request = lastTranscriptionRequest else {
            log.info("retry requested but no cached audio; falling back to Open Settings toast")
            handleTranscriptionFailure(
                reason: .missingProvider,
                message: "Nothing to retry. Open Settings to check your configuration."
            )
            return
        }
        state = .transcribing
        hotkey.setAppState(.transcribing)
        Task { @MainActor in
            await self.runTranscription(
                encoded: request.encoded,
                language: request.language,
                audioDuration: request.audioDuration
            )
        }
    }

    var currentTranscriptionModelID: String {
        switch settings.provider {
        case .openai:
            settings.openAIModel.rawValue
        case .groq:
            settings.groqModel.rawValue
        }
    }

    func openSettingsWindow() {
        SettingsWindowController.show(coordinator: self)
    }

    private static func destinationUsed(for settings: TranscriptionOutputSettings) -> String {
        switch (settings.saveToClipboard, settings.autoPaste) {
        case (true, true):
            return "clipboardAndAutoPaste"
        case (true, false):
            return "clipboard"
        case (false, true):
            return "autoPaste"
        case (false, false):
            return "none"
        }
    }

    private static func audioLevels(_ buffer: AudioBuffer) -> (rmsDbFS: Double, peakDbFS: Double) {
        let bytes = buffer.samples
        guard bytes.count >= 2 else {
            return (-Double.infinity, -Double.infinity)
        }

        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0

        bytes.withUnsafeBytes { rawBuffer in
            let byteBuffer = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < byteBuffer.count {
                let low = UInt16(byteBuffer[index])
                let high = UInt16(byteBuffer[index + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                let normalized = abs(Double(sample) / Double(Int16.max))
                sumSquares += normalized * normalized
                peak = max(peak, normalized)
                sampleCount += 1
                index += 2
            }
        }

        guard sampleCount > 0 else {
            return (-Double.infinity, -Double.infinity)
        }

        let rms = sqrt(sumSquares / Double(sampleCount))
        return (dbFS(rms), dbFS(peak))
    }

    private static func dbFS(_ value: Double) -> Double {
        guard value > 0 else { return -Double.infinity }
        return 20 * log10(value)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        switch loginItem.setEnabled(enabled) {
        case .success(let actual):
            launchAtLoginEnabled = actual
            launchAtLoginError = nil
        case .failure(let error):
            launchAtLoginEnabled = loginItem.isEnabled
            switch error {
            case .registerFailed(let message):
                launchAtLoginError = "Couldn't enable launch at login: \(message)"
            case .unregisterFailed(let message):
                launchAtLoginError = "Couldn't disable launch at login: \(message)"
            }
        }
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = loginItem.isEnabled
    }

    func openMenuBarPopover() {
        openMenuBarPopoverHandler?()
    }

    private func handleTranscriptionFailure(reason: ToastReason, message: String) {
        state = .error(message)
        hotkey.setAppState(.idle)
        playSound(.error)
        let content = ToastDecision.content(
            reason: reason,
            message: message,
            hasCachedAudio: lastTranscriptionRequest != nil
        )
        toastPresenter.show(content: content) { [weak self] in
            guard let self else { return }
            switch content.action {
            case .retry:
                self.retryLastTranscription()
            case .openSettings:
                self.openSettingsWindow()
            case .none:
                break
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

        settings.$historyMaxEntries
            .removeDuplicates()
            .sink { [weak self] value in
                self?.history.setMaxEntries(value)
            }
            .store(in: &cancellables)
    }
}
