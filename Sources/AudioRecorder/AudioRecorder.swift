import Foundation
import os
@preconcurrency import AVFoundation

private let recorderLog = Logger(subsystem: "WhisperKey", category: "AudioRecorder")

public struct AudioBuffer: Sendable, Equatable {
    public let samples: Data            // 16-bit signed little-endian PCM
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(samples: Data, sampleRate: Double, channelCount: UInt32) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var duration: TimeInterval {
        let bytesPerSample: Double = 2 * Double(channelCount)
        let totalSamples = Double(samples.count) / bytesPerSample
        return totalSamples / sampleRate
    }
}

public enum AudioRecorderError: Error, Equatable {
    case microphonePermissionDenied
    case engineFailedToStart(String)
    case alreadyRecording
}

/// Captures microphone audio into an in-memory PCM buffer at 16 kHz mono 16-bit.
///
/// - Discards recordings shorter than 300 ms (returns `nil` from `stop`).
/// - When `maxDuration` is reached, fires the handler registered via
///   `setOnMaxDurationReached`. The handler is expected to drive the same
///   stop/transcribe path as a manual stop.
public actor AudioRecorder {
    public static let minDuration: TimeInterval = 0.3
    public static let defaultMaxDuration: TimeInterval = 10 * 60

    public let maxDuration: TimeInterval

    private let engine = AVAudioEngine()
    private let outputFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Failed to create 16 kHz mono Int16 AVAudioFormat")
        }
        return format
    }()

    private var converter: AVAudioConverter?
    private var pcmData = Data()
    private var isRecording = false
    private var startTime: Date?
    private var maxDurationTask: Task<Void, Never>?
    private var onMaxDurationReached: (@Sendable () async -> Void)?

    public init(maxDuration: TimeInterval = AudioRecorder.defaultMaxDuration) {
        self.maxDuration = maxDuration
    }

    /// Registers a callback fired when `maxDuration` is reached.
    /// The handler is responsible for invoking the manual-stop flow.
    public func setOnMaxDurationReached(_ handler: (@Sendable () async -> Void)?) {
        onMaxDurationReached = handler
    }

    public var sampleRate: Double { outputFormat.sampleRate }
    public var channelCount: UInt32 { outputFormat.channelCount }

    public func start() async throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }
        try await ensureMicrophonePermission()
        try beginCapture()
    }

    public func stop() -> AudioBuffer? {
        guard isRecording else { return nil }
        isRecording = false

        maxDurationTask?.cancel()
        maxDurationTask = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let captured = pcmData
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        pcmData.removeAll(keepingCapacity: false)
        startTime = nil
        converter = nil

        guard elapsed >= Self.minDuration, !captured.isEmpty else {
            return nil
        }
        return AudioBuffer(
            samples: captured,
            sampleRate: outputFormat.sampleRate,
            channelCount: outputFormat.channelCount
        )
    }

    // MARK: - Internals

    private func ensureMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        recorderLog.info("ensureMicrophonePermission: authorizationStatus=\(status.rawValue, privacy: .public) (\(Self.statusName(status), privacy: .public))")
        switch status {
        case .authorized:
            return
        case .notDetermined:
            recorderLog.info("ensureMicrophonePermission: prompting via AVCaptureDevice.requestAccess")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            recorderLog.info("ensureMicrophonePermission: requestAccess returned \(granted, privacy: .public)")
            if !granted { throw AudioRecorderError.microphonePermissionDenied }
        case .denied, .restricted:
            recorderLog.error("ensureMicrophonePermission: TCC reports \(Self.statusName(status), privacy: .public) — bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)")
            throw AudioRecorderError.microphonePermissionDenied
        @unknown default:
            throw AudioRecorderError.microphonePermissionDenied
        }
    }

    private static func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private func beginCapture() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.engineFailedToStart("converter init failed")
        }
        self.converter = converter

        pcmData.removeAll(keepingCapacity: true)

        let outputFormat = self.outputFormat
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { await self.append(buffer: buffer, inputFormat: inputFormat, outputFormat: outputFormat) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        isRecording = true
        startTime = Date()

        scheduleMaxDurationTask()
    }

    private func scheduleMaxDurationTask() {
        let duration = maxDuration
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.handleMaxDurationReached()
        }
    }

    private func append(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard isRecording, let converter else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var error: NSError?
        var didProvide = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if didProvide {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvide = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else { return }

        let frameCount = Int(outputBuffer.frameLength)
        guard let int16Channel = outputBuffer.int16ChannelData?.pointee else { return }
        let byteCount = frameCount * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
        pcmData.append(UnsafeBufferPointer(start: int16Channel, count: frameCount * Int(outputFormat.channelCount)).withMemoryRebound(to: UInt8.self) { ptr in
            Data(bytes: ptr.baseAddress!, count: byteCount)
        })
    }

    private func handleMaxDurationReached() async {
        guard let handler = onMaxDurationReached else { return }
        await handler()
    }

    // MARK: - Test hooks

    /// Schedules the max-duration task without starting the audio engine.
    /// Test-only — exposed via `@testable import`.
    internal func _armMaxDurationTaskForTesting() {
        scheduleMaxDurationTask()
    }

    /// Cancels the scheduled max-duration task.
    /// Test-only — exposed via `@testable import`.
    internal func _cancelMaxDurationTaskForTesting() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
    }
}
