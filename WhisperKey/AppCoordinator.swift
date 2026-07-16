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
import UsageStatsStore

enum PermissionWindowZOrderState: Equatable {
    case aboveOrdinaryApps
    case yieldingToMicrophonePrompt
    case yieldingToAccessibilityPrompt
    case yieldingToSystemSettings
}

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

    private enum ProcessingPhase: String {
        case recordingStop
        case encode
        case transcription
        case outputDelivery
    }

    private struct ProcessingMetrics {
        var providerID: String
        var modelID: String
        var audioDuration: TimeInterval?
        var byteSize: Int?
    }

    static let processingTimeout: TimeInterval = 30

    @Published private(set) var state: AppState = .idle
    @Published var permissions = PermissionState.current()
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published var launchAtLoginError: String?

    func updateState(_ new: AppState) { state = new }

    static func canStartRecording(from state: AppState) -> Bool {
        switch state {
        case .idle, .error:
            return true
        case .recording, .transcribing, .microphoneDenied, .accessibilityDenied:
            return false
        }
    }

    let settings: SettingsStore
    let hotkey: HotkeyEngineRunner
    let history: HistoryStore
    let usageStats: UsageStatsStore
    private let loginItem: LoginItemController

    private let recorder = AudioRecorder()
    private let encoder = AudioEncoder()
    private let sounds = SoundPlayer()
    private let appleMusic = AppleMusicRecordingController()
    private let outputRouter = TranscriptionOutputRouter()
    private let toastPresenter = ToastPresenter()
    private let log = Logger(subsystem: "WhisperKey", category: "AppCoordinator")
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartedAt: Date?
    private var recordingTimerTask: Task<Void, Never>?
    private var welcomePresentationWorkItem: DispatchWorkItem?
    private var activeRecordingID: UUID?
    private var recordingCancellationRequested = false
    private var activeProcessingID: UUID?
    private var activeProcessingPhase: ProcessingPhase?
    private var activeProcessingStartedAt: Date?
    private var activeProcessingMetrics: ProcessingMetrics?
    private var processingTask: Task<Void, Never>?
    private var processingTimeoutTask: Task<Void, Never>?
    private var lastTranscriptionRequest: (encoded: EncodedAudio, language: String?, audioDuration: TimeInterval)?
    var hotkeyStarted = false
    var permissionPollTask: Task<Void, Never>?
    var workspaceActivationObserver: NSObjectProtocol?
    var onboardingWindowController: OnboardingWindowController?
    var welcomeWindowController: WelcomeWindowController?
    var openMenuBarPopoverHandler: (() -> Void)?
    var closeMenuBarPopoverHandler: (() -> Void)?
    var permissionWindowZOrderState: PermissionWindowZOrderState = .aboveOrdinaryApps

    init(
        settings: SettingsStore? = nil,
        history: HistoryStore? = nil,
        usageStats: UsageStatsStore? = nil,
        loginItemService: LoginItemService? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        self.settings = resolvedSettings
        self.history = history ?? HistoryStore(maxEntries: resolvedSettings.historyMaxEntries)
        let resolvedUsageStats = usageStats ?? UsageStatsStore()
        self.usageStats = resolvedUsageStats
        self.hotkey = HotkeyEngineRunner(config: resolvedSettings.hotkeyConfig)
        let resolvedLoginService = loginItemService ?? SMAppServiceLoginItem()
        self.loginItem = LoginItemController(service: resolvedLoginService)
        self.launchAtLoginEnabled = self.loginItem.isEnabled

        if resolvedSettings.consumePendingInstallUsageReset() {
            resolvedUsageStats.resetAll()
            log.info("usage counters reset due to fresh install marker")
        }

        hotkey.setOutputHandler { [weak self] output in
            guard let self else { return }
            Task { @MainActor in self.handle(output) }
        }

        observeSettings()
        observeWorkspaceActivation()
        startPermissionPolling()

        onboardingWindowController = OnboardingWindowController(coordinator: self)
        welcomeWindowController = WelcomeWindowController(coordinator: self)
        refreshPermissions(forceOnboarding: !resolvedSettings.hasPendingInstallWelcome)
    }

    deinit {
        permissionPollTask?.cancel()
        recordingTimerTask?.cancel()
        processingTask?.cancel()
        processingTimeoutTask?.cancel()
        welcomePresentationWorkItem?.cancel()
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
        case .recordingShouldCancel:
            cancelRecording()
        }
    }

    private func startRecording() {
        refreshPermissions()
        guard Self.canStartRecording(from: state), permissions.allGranted else { return }
        let recordingID = UUID()
        lastTranscriptionRequest = nil
        activeRecordingID = recordingID
        recordingCancellationRequested = false
        state = .recording
        hotkey.setAppState(.recording)
        appleMusic.recordingDidStart(enabled: settings.pauseAppleMusicWhileRecording)
        startRecordingTimer()
        toastPresenter.dismiss(animated: false)

        Task {
            do {
                await recorder.setOnMaxDurationReached { [weak self] in
                    guard let self else { return }
                    await MainActor.run { self.stopRecording() }
                }

                guard activeRecordingID == recordingID, !recordingCancellationRequested else {
                    finishCanceledRecording(recordingID: recordingID)
                    return
                }

                try await recorder.start()

                guard activeRecordingID == recordingID else {
                    _ = await recorder.stop()
                    return
                }

                if recordingCancellationRequested {
                    _ = await recorder.stop()
                    finishCanceledRecording(recordingID: recordingID)
                    return
                }

                playSound(.start)
            } catch AudioRecorderError.microphonePermissionDenied {
                guard activeRecordingID == recordingID else { return }
                if recordingCancellationRequested {
                    finishCanceledRecording(recordingID: recordingID)
                    return
                }
                log.error("microphone permission denied")
                await MainActor.run {
                    self.appleMusic.recordingDidEnd()
                    stopRecordingTimer()
                    activeRecordingID = nil
                    recordingCancellationRequested = false
                    state = .microphoneDenied
                    hotkey.setAppState(.idle)
                    playSound(.error)
                }
            } catch {
                guard activeRecordingID == recordingID else { return }
                if recordingCancellationRequested {
                    finishCanceledRecording(recordingID: recordingID)
                    return
                }
                log.error("recorder.start failed: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    self.appleMusic.recordingDidEnd()
                    stopRecordingTimer()
                    activeRecordingID = nil
                    recordingCancellationRequested = false
                    state = .error("Recording failed: \(error)")
                    hotkey.setAppState(.idle)
                    playSound(.error)
                }
            }
        }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let recordingID = activeRecordingID
        let operationID = UUID()
        recordingCancellationRequested = false
        beginProcessing(operationID: operationID)
        state = .transcribing
        hotkey.setAppState(.transcribing)
        log.info("transcription in flight; further hotkey presses will be suppressed")
        stopRecordingTimer()
        playSound(.stop)
        setProcessingPhase(.recordingStop, operationID: operationID)
        log.info("recording stop started operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) elapsed=0")

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let buffer = await recorder.stop()
            self.appleMusic.recordingDidEnd()

            guard self.activeRecordingID == recordingID, self.isCurrentProcessing(operationID) else {
                self.log.info("recording stop finished after cancellation; ignoring operationID=\(operationID.uuidString, privacy: .public)")
                return
            }
            self.activeRecordingID = nil

            guard let buffer else {
                self.log.info("recording stop finished operationID=\(operationID.uuidString, privacy: .public) audioDuration=0 pcmBytes=0 elapsed=\(self.processingElapsed(), privacy: .public)")
                self.log.info("recording discarded (under min duration) operationID=\(operationID.uuidString, privacy: .public)")
                self.completeProcessing(operationID: operationID, clearCachedAudio: true, playDoneSound: false)
                return
            }

            self.activeProcessingMetrics?.audioDuration = buffer.duration
            self.activeProcessingMetrics?.byteSize = buffer.samples.count
            self.log.info("recording stop finished operationID=\(operationID.uuidString, privacy: .public) audioDuration=\(buffer.duration, privacy: .public) pcmBytes=\(buffer.samples.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")

            await self.transcribeNew(buffer: buffer, operationID: operationID)
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        let recordingID = activeRecordingID
        recordingCancellationRequested = true
        lastTranscriptionRequest = nil
        stopRecordingTimer()
        log.info("recording cancellation requested")

        Task {
            _ = await recorder.stop()
            appleMusic.recordingDidEnd()
            finishCanceledRecording(recordingID: recordingID)
        }
    }

    private func finishCanceledRecording(recordingID: UUID?) {
        guard activeRecordingID == recordingID else { return }
        log.info("recording canceled; captured audio discarded")
        activeRecordingID = nil
        recordingCancellationRequested = false
        lastTranscriptionRequest = nil
        stopRecordingTimer()
        state = .idle
        hotkey.setAppState(.idle)
    }

    func cancelActiveOperation() {
        switch state {
        case .recording:
            cancelRecording()
        case .transcribing:
            cancelProcessingManually()
        case .idle, .error, .microphoneDenied, .accessibilityDenied:
            break
        }
    }

    private func cancelProcessingManually() {
        guard state == .transcribing else { return }
        let operationID = activeProcessingID
        let metrics = activeProcessingMetrics
        log.info("manual cancel operationID=\(operationID?.uuidString ?? "nil", privacy: .public) phase=\(self.activeProcessingPhase?.rawValue ?? "none", privacy: .public) provider=\(metrics?.providerID ?? self.settings.provider.rawValue, privacy: .public) model=\(metrics?.modelID ?? self.currentTranscriptionModelID, privacy: .public) audioDuration=\(metrics?.audioDuration ?? -1, privacy: .public) bytes=\(metrics?.byteSize ?? -1, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
        processingTask?.cancel()
        processingTimeoutTask?.cancel()
        processingTask = nil
        processingTimeoutTask = nil
        activeProcessingID = nil
        activeProcessingPhase = nil
        activeProcessingStartedAt = nil
        activeProcessingMetrics = nil
        activeRecordingID = nil
        recordingCancellationRequested = false
        stopRecordingTimer()
        toastPresenter.dismiss(animated: false)
        state = .idle
        hotkey.setAppState(.idle)

        Task {
            _ = await recorder.stop()
            appleMusic.recordingDidEnd()
        }
    }

    private func transcribeNew(buffer: AudioBuffer, operationID: UUID) async {
        guard isCurrentProcessing(operationID) else { return }
        let language = settings.language.isoCode
        let encoded: EncodedAudio
        do {
            setProcessingPhase(.encode, operationID: operationID)
            log.info("encode started operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(buffer.duration, privacy: .public) pcmBytes=\(buffer.samples.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
            try Task.checkCancellation()
            encoded = try encoder.encode(buffer)
            try Task.checkCancellation()
        } catch {
            guard isCurrentProcessing(operationID), !Task.isCancelled else { return }
            log.error("encode failed operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(buffer.duration, privacy: .public) pcmBytes=\(buffer.samples.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public) error=\(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastTranscriptionRequest = nil
            self.handleTranscriptionFailure(operationID: operationID, reason: .transcription(.unknown), message: message)
            return
        }

        let audioDuration = buffer.duration
        let levels = Self.audioLevels(buffer)
        log.info("recording captured duration=\(audioDuration, privacy: .public) pcmBytes=\(buffer.samples.count, privacy: .public) sampleRate=\(buffer.sampleRate, privacy: .public) channels=\(buffer.channelCount, privacy: .public) rmsDbFS=\(levels.rmsDbFS, privacy: .public) peakDbFS=\(levels.peakDbFS, privacy: .public)")
        activeProcessingMetrics?.audioDuration = audioDuration
        activeProcessingMetrics?.byteSize = encoded.data.count
        log.info("encode finished operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")

        self.lastTranscriptionRequest = (encoded, language, audioDuration)
        await runTranscription(encoded: encoded, language: language, audioDuration: audioDuration, operationID: operationID)
    }

    private func runTranscription(encoded: EncodedAudio, language: String?, audioDuration: TimeInterval, operationID: UUID) async {
        guard isCurrentProcessing(operationID) else { return }
        guard let provider = settings.makeTranscriptionProvider() else {
            log.error("no provider configured; cannot transcribe")
            handleTranscriptionFailure(
                operationID: operationID,
                reason: .missingProvider,
                message: "Set the API key in Settings."
            )
            return
        }

        do {
            setProcessingPhase(.transcription, operationID: operationID)
            log.info("transcription started operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) mimeType=\(encoded.mimeType, privacy: .public) extension=\(encoded.fileExtension, privacy: .public) bytes=\(encoded.data.count, privacy: .public) audioDuration=\(audioDuration, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
            try Task.checkCancellation()
            let text = try await provider.transcribe(audio: encoded, language: language)
            try Task.checkCancellation()
            guard isCurrentProcessing(operationID) else {
                log.info("provider response ignored for stale operationID=\(operationID.uuidString, privacy: .public)")
                return
            }
            let trimmedLength = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            log.info("provider response operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public) chars=\(text.count, privacy: .public) trimmedChars=\(trimmedLength, privacy: .public)")
            log.info("transcription parsed chars=\(text.count, privacy: .public) trimmedChars=\(trimmedLength, privacy: .public)")

            guard trimmedLength > 0 else {
                log.info("empty transcription result; clipboard and paste skipped provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public)")
                completeProcessing(operationID: operationID, clearCachedAudio: true, playDoneSound: true)
                return
            }

            let outputSettings = TranscriptionOutputSettings(
                saveToClipboard: settings.saveTranscriptionToClipboard,
                autoPaste: settings.autoPasteTranscription
            )
            setProcessingPhase(.outputDelivery, operationID: operationID)
            log.info("output delivery started operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) saveToClipboard=\(outputSettings.saveToClipboard, privacy: .public) autoPaste=\(outputSettings.autoPaste, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
            try Task.checkCancellation()
            let output = await outputRouter.deliver(text: text, settings: outputSettings)
            try Task.checkCancellation()
            guard isCurrentProcessing(operationID) else {
                log.info("output delivery result ignored for stale operationID=\(operationID.uuidString, privacy: .public)")
                return
            }
            log.info("output delivery finished operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public) wroteClipboard=\(output.wroteClipboard, privacy: .public) pasteDecision=\(String(describing: output.pasteDecision), privacy: .public) restoredClipboard=\(output.restoredClipboard, privacy: .public)")
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
            if priceEstimate == nil {
                log.error("missing pricing rule for provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public); usage cost will be omitted")
            }
            usageStats.record(
                providerID: settings.provider.rawValue,
                modelID: currentTranscriptionModelID,
                wordCount: HistoryEntry.countWords(in: text),
                audioDurationSeconds: audioDuration,
                estimatedPriceAtTime: priceEstimate?.amount,
                currency: priceEstimate?.currency
            )
            completeProcessing(operationID: operationID, clearCachedAudio: true, playDoneSound: true)
        } catch is CancellationError {
            log.info("processing task cancelled operationID=\(operationID.uuidString, privacy: .public) phase=\(self.activeProcessingPhase?.rawValue ?? "none", privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
        } catch let error as TranscriptionError {
            guard isCurrentProcessing(operationID) else {
                log.info("provider error ignored for stale operationID=\(operationID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return
            }
            log.error("provider error operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public) error=\(String(describing: error), privacy: .public)")
            let message = error.errorDescription ?? "Transcription failed."
            handleTranscriptionFailure(operationID: operationID, reason: .transcription(error.category), message: message)
        } catch {
            guard isCurrentProcessing(operationID) else {
                log.info("provider error ignored for stale operationID=\(operationID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return
            }
            log.error("provider error operationID=\(operationID.uuidString, privacy: .public) provider=\(self.settings.provider.rawValue, privacy: .public) model=\(self.currentTranscriptionModelID, privacy: .public) audioDuration=\(audioDuration, privacy: .public) bytes=\(encoded.data.count, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public) error=\(String(describing: error), privacy: .public)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            handleTranscriptionFailure(operationID: operationID, reason: .transcription(.unknown), message: message)
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
        let operationID = UUID()
        beginProcessing(operationID: operationID)
        activeProcessingMetrics?.audioDuration = request.audioDuration
        activeProcessingMetrics?.byteSize = request.encoded.data.count
        state = .transcribing
        hotkey.setAppState(.transcribing)
        processingTask = Task { @MainActor in
            await self.runTranscription(
                encoded: request.encoded,
                language: request.language,
                audioDuration: request.audioDuration,
                operationID: operationID
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

    func presentWelcomeIfNeeded() {
        let hasPendingInstallWelcome = settings.hasPendingInstallWelcome
        log.info("presentWelcomeIfNeeded pending=\(hasPendingInstallWelcome, privacy: .public)")
        guard hasPendingInstallWelcome else { return }

        welcomeWindowController?.show()
    }

    func scheduleWelcomePresentationAfterLaunch() {
        welcomePresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.presentWelcomeIfNeeded()
            }
        }
        welcomePresentationWorkItem = workItem
        log.info("scheduled welcome presentation after launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    var shouldSuppressPermissionOnboardingForWelcome: Bool {
        settings.hasPendingInstallWelcome
    }

    func completeWelcome(openSettings: Bool) {
        welcomePresentationWorkItem?.cancel()
        settings.markInstallWelcomePresented()
        welcomeWindowController?.close()

        guard openSettings else { return }
        openMenuBarPopover()

        // Let the popover finish its deferred ordering before putting Settings on top.
        DispatchQueue.main.async { [weak self] in
            self?.openSettingsWindow()
        }
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

    private func beginProcessing(operationID: UUID) {
        processingTask?.cancel()
        processingTimeoutTask?.cancel()
        activeProcessingID = operationID
        activeProcessingPhase = nil
        activeProcessingStartedAt = Date()
        activeProcessingMetrics = ProcessingMetrics(
            providerID: settings.provider.rawValue,
            modelID: currentTranscriptionModelID,
            audioDuration: nil,
            byteSize: nil
        )
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.processingTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.handleProcessingTimeout(operationID: operationID)
            }
        }
    }

    private static var processingTimeoutNanoseconds: UInt64 {
        UInt64((processingTimeout * 1_000_000_000).rounded(.up))
    }

    private func setProcessingPhase(_ phase: ProcessingPhase, operationID: UUID) {
        guard activeProcessingID == operationID else { return }
        activeProcessingPhase = phase
    }

    private func isCurrentProcessing(_ operationID: UUID) -> Bool {
        activeProcessingID == operationID
    }

    private func processingElapsed() -> TimeInterval {
        activeProcessingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func completeProcessing(operationID: UUID, clearCachedAudio: Bool, playDoneSound: Bool) {
        guard isCurrentProcessing(operationID) else { return }
        if clearCachedAudio {
            lastTranscriptionRequest = nil
        }
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        processingTask = nil
        activeProcessingID = nil
        activeProcessingPhase = nil
        activeProcessingStartedAt = nil
        activeProcessingMetrics = nil
        activeRecordingID = nil
        state = .idle
        hotkey.setAppState(.idle)
        if playDoneSound {
            playSound(.done)
        }
    }

    private func handleProcessingTimeout(operationID: UUID) {
        guard isCurrentProcessing(operationID) else { return }
        let metrics = activeProcessingMetrics
        let phase = activeProcessingPhase
        log.error("processing timeout operationID=\(operationID.uuidString, privacy: .public) phase=\(self.activeProcessingPhase?.rawValue ?? "none", privacy: .public) provider=\(metrics?.providerID ?? self.settings.provider.rawValue, privacy: .public) model=\(metrics?.modelID ?? self.currentTranscriptionModelID, privacy: .public) audioDuration=\(metrics?.audioDuration ?? -1, privacy: .public) bytes=\(metrics?.byteSize ?? -1, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
        log.error("provider timeout operationID=\(operationID.uuidString, privacy: .public) provider=\(metrics?.providerID ?? self.settings.provider.rawValue, privacy: .public) model=\(metrics?.modelID ?? self.currentTranscriptionModelID, privacy: .public) audioDuration=\(metrics?.audioDuration ?? -1, privacy: .public) bytes=\(metrics?.byteSize ?? -1, privacy: .public) elapsed=\(self.processingElapsed(), privacy: .public)")
        processingTask?.cancel()
        processingTimeoutTask?.cancel()
        processingTask = nil
        processingTimeoutTask = nil
        activeProcessingID = nil
        activeProcessingPhase = nil
        activeProcessingStartedAt = nil
        activeProcessingMetrics = nil
        activeRecordingID = nil
        handleTranscriptionFailure(
            reason: .transcription(.timedOut),
            message: Self.processingTimeoutMessage(
                phase: phase,
                providerID: metrics?.providerID ?? settings.provider.rawValue
            )
        )

        Task {
            _ = await recorder.stop()
            appleMusic.recordingDidEnd()
        }
    }

    private static func processingTimeoutMessage(phase: ProcessingPhase?, providerID: String) -> String {
        switch phase {
        case .recordingStop:
            return "WhisperKey spent 30 seconds finishing the recording on this Mac. This is a local audio-processing issue, not a provider error."
        case .encode:
            return "WhisperKey spent 30 seconds preparing the audio on this Mac. This is a local processing issue, not a provider error."
        case .transcription:
            let provider = TranscriptionProviderID(rawValue: providerID)?.displayName ?? providerID
            return "No response from \(provider) within 30 seconds. It may be your network or \(provider); no response arrived, so WhisperKey cannot tell which."
        case .outputDelivery:
            return "The transcription finished, but WhisperKey spent 30 seconds delivering the text on this Mac. This is a local output issue, not a provider error."
        case nil:
            return "WhisperKey stopped processing after 30 seconds before it could identify the stage. Try again."
        }
    }

    private func handleTranscriptionFailure(operationID: UUID, reason: ToastReason, message: String) {
        guard isCurrentProcessing(operationID) else { return }
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        processingTask = nil
        activeProcessingID = nil
        activeProcessingPhase = nil
        activeProcessingStartedAt = nil
        activeProcessingMetrics = nil
        activeRecordingID = nil
        handleTranscriptionFailure(reason: reason, message: message)
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
            .combineLatest(settings.$escapeToCancelRecording)
            .map { triggerAndMode, escapeToCancelRecording in
                HotkeyConfig(
                    trigger: triggerAndMode.0,
                    mode: triggerAndMode.1,
                    escapeToCancelRecording: escapeToCancelRecording
                )
            }
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
