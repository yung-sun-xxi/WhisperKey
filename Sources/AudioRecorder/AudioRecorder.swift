import Foundation
import os
@preconcurrency import AVFoundation
@preconcurrency import CoreAudio

private let recorderLog = Logger(subsystem: "WhisperKey", category: "AudioRecorder")

private struct AudioInputDeviceSnapshot: Equatable, Sendable {
    let objectID: AudioObjectID
    let name: String?
    let uid: String?

    var logDescription: String {
        "id=\(objectID) name=\(name ?? "nil") uid=\(uid ?? "nil")"
    }

    static func currentDefault() -> AudioInputDeviceSnapshot? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            recorderLog.error("defaultInputDevice: AudioObjectGetPropertyData failed status=\(status, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            return nil
        }

        return AudioInputDeviceSnapshot(
            objectID: deviceID,
            name: stringProperty(kAudioObjectPropertyName, objectID: deviceID),
            uid: stringProperty(kAudioDevicePropertyDeviceUID, objectID: deviceID)
        )
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )

        guard status == noErr else {
            recorderLog.error("audioObjectStringProperty: selector=\(selector, privacy: .public) objectID=\(objectID, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }
}

private struct AudioCaptureMetrics: Sendable {
    var tapBuffersScheduled: UInt64 = 0
    var appendAttempts: UInt64 = 0
    var appendedBuffers: UInt64 = 0
    var converterFailures: UInt64 = 0
    var outputAllocationFailures: UInt64 = 0
    var emptyOutputBuffers: UInt64 = 0
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var totalQueueDelayNanos: UInt64 = 0
    var maxQueueDelayNanos: UInt64 = 0
    var totalAppendNanos: UInt64 = 0
    var maxAppendNanos: UInt64 = 0
    var maxEstimatedPendingTasks: UInt64 = 0

    var averageQueueDelayMillis: Double {
        guard appendAttempts > 0 else { return 0 }
        return Self.millis(totalQueueDelayNanos) / Double(appendAttempts)
    }

    var maxQueueDelayMillis: Double {
        Self.millis(maxQueueDelayNanos)
    }

    var averageAppendMillis: Double {
        guard appendAttempts > 0 else { return 0 }
        return Self.millis(totalAppendNanos) / Double(appendAttempts)
    }

    var maxAppendMillis: Double {
        Self.millis(maxAppendNanos)
    }

    mutating func recordAppendStart(tapBufferID: UInt64, inputFrameLength: AVAudioFrameCount, queueDelayNanos: UInt64) {
        tapBuffersScheduled = max(tapBuffersScheduled, tapBufferID)
        appendAttempts += 1
        inputFrames += UInt64(inputFrameLength)
        totalQueueDelayNanos += queueDelayNanos
        maxQueueDelayNanos = max(maxQueueDelayNanos, queueDelayNanos)
        maxEstimatedPendingTasks = max(maxEstimatedPendingTasks, estimatedPendingTasks)
    }

    mutating func recordOutputAllocationFailure(appendNanos: UInt64) {
        outputAllocationFailures += 1
        recordAppendDuration(appendNanos)
    }

    mutating func recordConverterFailure(appendNanos: UInt64) {
        converterFailures += 1
        recordAppendDuration(appendNanos)
    }

    mutating func recordEmptyOutputBuffer(appendNanos: UInt64) {
        emptyOutputBuffers += 1
        recordAppendDuration(appendNanos)
    }

    mutating func recordAppendSuccess(outputFrameLength: AVAudioFrameCount, appendNanos: UInt64) {
        appendedBuffers += 1
        outputFrames += UInt64(outputFrameLength)
        recordAppendDuration(appendNanos)
    }

    private var finishedBuffers: UInt64 {
        appendedBuffers + converterFailures + outputAllocationFailures + emptyOutputBuffers
    }

    private var estimatedPendingTasks: UInt64 {
        tapBuffersScheduled > finishedBuffers ? tapBuffersScheduled - finishedBuffers : 0
    }

    private mutating func recordAppendDuration(_ nanos: UInt64) {
        totalAppendNanos += nanos
        maxAppendNanos = max(maxAppendNanos, nanos)
    }

    private static func millis(_ nanos: UInt64) -> Double {
        Double(nanos) / 1_000_000
    }
}

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

    private var engine = AVAudioEngine()
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
    private var activeCaptureID: UInt64?
    private var nextCaptureID: UInt64 = 1
    private var activeInputDevice: AudioInputDeviceSnapshot?
    private var lastInputDevice: AudioInputDeviceSnapshot?
    private var activeCaptureMetrics: AudioCaptureMetrics?
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
        let capturedDuration = capturedDuration(byteCount: captured.count)
        let expectedBytes = expectedByteCount(duration: elapsed)
        let capturedByteDelta = captured.count - expectedBytes
        let captureDurationRatio = elapsed > 0 ? capturedDuration / elapsed : 0
        recorderLog.info(
            "stop: captureID=\(self.activeCaptureID ?? 0, privacy: .public) elapsed=\(elapsed, privacy: .public) capturedBytes=\(captured.count, privacy: .public) expectedBytes=\(expectedBytes, privacy: .public) capturedByteDelta=\(capturedByteDelta, privacy: .public) capturedDuration=\(capturedDuration, privacy: .public) captureDurationRatio=\(captureDurationRatio, privacy: .public) inputDevice=\(self.activeInputDevice?.logDescription ?? "nil", privacy: .public)"
        )
        if let metrics = activeCaptureMetrics {
            recorderLog.info(
                "captureMetrics: captureID=\(self.activeCaptureID ?? 0, privacy: .public) tapBuffers=\(metrics.tapBuffersScheduled, privacy: .public) appendAttempts=\(metrics.appendAttempts, privacy: .public) appendedBuffers=\(metrics.appendedBuffers, privacy: .public) converterFailures=\(metrics.converterFailures, privacy: .public) outputAllocationFailures=\(metrics.outputAllocationFailures, privacy: .public) emptyOutputBuffers=\(metrics.emptyOutputBuffers, privacy: .public) inputFrames=\(metrics.inputFrames, privacy: .public) outputFrames=\(metrics.outputFrames, privacy: .public) avgQueueMs=\(metrics.averageQueueDelayMillis, privacy: .public) maxQueueMs=\(metrics.maxQueueDelayMillis, privacy: .public) avgAppendMs=\(metrics.averageAppendMillis, privacy: .public) maxAppendMs=\(metrics.maxAppendMillis, privacy: .public) maxEstimatedPendingTasks=\(metrics.maxEstimatedPendingTasks, privacy: .public)"
            )
        }
        pcmData.removeAll(keepingCapacity: false)
        startTime = nil
        converter = nil
        activeCaptureID = nil
        activeInputDevice = nil
        activeCaptureMetrics = nil

        guard elapsed >= Self.minDuration, !captured.isEmpty else {
            recorderLog.info(
                "stop: discarding capture elapsed=\(elapsed, privacy: .public) minDuration=\(Self.minDuration, privacy: .public) capturedBytes=\(captured.count, privacy: .public)"
            )
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
        let captureID = nextCaptureID
        nextCaptureID += 1
        let inputDevice = AudioInputDeviceSnapshot.currentDefault()
        let didInputDeviceChange = lastInputDevice.map { $0 != inputDevice } ?? false

        recorderLog.info(
            "beginCapture: captureID=\(captureID, privacy: .public) defaultInput=\(inputDevice?.logDescription ?? "nil", privacy: .public) inputDeviceChangedSincePrevious=\(didInputDeviceChange, privacy: .public)"
        )

        // Recreate the engine each capture so the input node's cached format
        // matches the current hardware. AVAudioEngine caches the format from
        // the first activation; if the user switches audio devices (e.g.
        // unplugs headphones), reusing the same engine causes installTap to
        // throw an Obj-C exception on format mismatch, which crashes the app.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        recorderLog.info(
            "beginCapture: captureID=\(captureID, privacy: .public) inputFormat sampleRate=\(inputFormat.sampleRate, privacy: .public) channelCount=\(inputFormat.channelCount, privacy: .public) commonFormat=\(inputFormat.commonFormat.rawValue, privacy: .public) interleaved=\(inputFormat.isInterleaved, privacy: .public)"
        )

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) invalid input format \(String(describing: inputFormat), privacy: .public)")
            throw AudioRecorderError.engineFailedToStart("invalid input format \(inputFormat)")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) converter init failed")
            throw AudioRecorderError.engineFailedToStart("converter init failed")
        }
        self.converter = converter
        self.activeCaptureMetrics = AudioCaptureMetrics()

        pcmData.removeAll(keepingCapacity: true)

        let outputFormat = self.outputFormat
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) installing input tap")
        var tapBufferSequence: UInt64 = 0
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            tapBufferSequence += 1
            let tapBufferID = tapBufferSequence
            let enqueuedAtNanos = Self.nowNanos()
            let inputFrameLength = buffer.frameLength
            Task {
                await self.append(
                    buffer: buffer,
                    inputFormat: inputFormat,
                    outputFormat: outputFormat,
                    captureID: captureID,
                    tapBufferID: tapBufferID,
                    inputFrameLength: inputFrameLength,
                    enqueuedAtNanos: enqueuedAtNanos
                )
            }
        }
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) input tap installed")

        engine.prepare()
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) engine prepared; starting")
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) engine.start failed: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        isRecording = true
        startTime = Date()
        activeCaptureID = captureID
        activeInputDevice = inputDevice
        lastInputDevice = inputDevice
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) engine started")

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

    private func append(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        captureID: UInt64,
        tapBufferID: UInt64,
        inputFrameLength: AVAudioFrameCount,
        enqueuedAtNanos: UInt64
    ) {
        let startedAtNanos = Self.nowNanos()
        guard isRecording, activeCaptureID == captureID, let converter else {
            recorderLog.info(
                "append: captureID=\(captureID, privacy: .public) tapBufferID=\(tapBufferID, privacy: .public) ignored because capture is no longer active"
            )
            return
        }

        activeCaptureMetrics?.recordAppendStart(
            tapBufferID: tapBufferID,
            inputFrameLength: inputFrameLength,
            queueDelayNanos: startedAtNanos - enqueuedAtNanos
        )

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            activeCaptureMetrics?.recordOutputAllocationFailure(appendNanos: Self.nowNanos() - startedAtNanos)
            recorderLog.error(
                "append: captureID=\(captureID, privacy: .public) tapBufferID=\(tapBufferID, privacy: .public) output buffer allocation failed capacity=\(outputCapacity, privacy: .public)"
            )
            return
        }

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

        guard status != .error, error == nil else {
            activeCaptureMetrics?.recordConverterFailure(appendNanos: Self.nowNanos() - startedAtNanos)
            recorderLog.error(
                "append: captureID=\(captureID, privacy: .public) tapBufferID=\(tapBufferID, privacy: .public) converter failed status=\(status.rawValue, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)"
            )
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let int16Channel = outputBuffer.int16ChannelData?.pointee else {
            activeCaptureMetrics?.recordEmptyOutputBuffer(appendNanos: Self.nowNanos() - startedAtNanos)
            return
        }
        let byteCount = frameCount * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
        pcmData.append(UnsafeBufferPointer(start: int16Channel, count: frameCount * Int(outputFormat.channelCount)).withMemoryRebound(to: UInt8.self) { ptr in
            Data(bytes: ptr.baseAddress!, count: byteCount)
        })
        activeCaptureMetrics?.recordAppendSuccess(
            outputFrameLength: outputBuffer.frameLength,
            appendNanos: Self.nowNanos() - startedAtNanos
        )
    }

    private func handleMaxDurationReached() async {
        guard let handler = onMaxDurationReached else { return }
        await handler()
    }

    private func capturedDuration(byteCount: Int) -> TimeInterval {
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else { return 0 }
        let bytesPerSample = Double(MemoryLayout<Int16>.size) * Double(outputFormat.channelCount)
        return Double(byteCount) / bytesPerSample / outputFormat.sampleRate
    }

    private func expectedByteCount(duration: TimeInterval) -> Int {
        guard duration > 0, outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else { return 0 }
        let bytesPerSecond = outputFormat.sampleRate * Double(outputFormat.channelCount) * Double(MemoryLayout<Int16>.size)
        return Int((duration * bytesPerSecond).rounded())
    }

    private nonisolated static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
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
