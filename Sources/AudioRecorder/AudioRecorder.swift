import Foundation
import os
@preconcurrency import AVFoundation
@preconcurrency import CoreAudio

private let recorderLog = Logger(subsystem: "WhisperKey", category: "AudioRecorder")

func audioRecorderNowNanos() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
        pcmFormat: source.format,
        frameCapacity: source.frameLength
    ) else {
        return nil
    }
    copy.frameLength = source.frameLength
    let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard sourceBuffers.count == destinationBuffers.count else { return nil }
    for index in sourceBuffers.indices {
        let sourceBuffer = sourceBuffers[index]
        let destinationBuffer = destinationBuffers[index]
        guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
            return nil
        }
        let byteCount = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
        destinationData.copyMemory(from: sourceData, byteCount: byteCount)
    }
    return copy
}

private final class AudioAppendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAppendQueued = false

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isAppendQueued else { return false }
        isAppendQueued = true
        return true
    }

    func release() {
        lock.lock()
        isAppendQueued = false
        lock.unlock()
    }
}

/// Averages every channel of a Float32 buffer into a new mono Float32 buffer
/// in `monoFormat`, at the same sample rate and frame count.
func downmixToMono(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let channels = Int(buffer.format.channelCount)
    guard
        channels > 0,
        let source = buffer.floatChannelData,
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(buffer.frameLength, 1)),
        let destination = mono.floatChannelData?[0]
    else {
        return nil
    }
    mono.frameLength = buffer.frameLength
    let frames = Int(buffer.frameLength)
    let scale = 1 / Float(channels)
    if buffer.format.isInterleaved {
        let samples = source[0]
        let stride = buffer.stride
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += samples[frame * stride + channel]
            }
            destination[frame] = sum * scale
        }
    } else {
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += source[channel][frame]
            }
            destination[frame] = sum * scale
        }
    }
    return mono
}

/// Owns the conversion work for exactly one microphone capture.
///
/// CoreAudio conversion is intentionally kept off `AudioRecorder`'s actor
/// executor. A converter that stops returning may strand this pipeline, but it
/// must not strand the controls for the current or a later recording.
///
/// The converter only ever sees mono input. A multichannel input is averaged
/// to mono first: `AVAudioConverter` has no downmix for a discrete layout (the
/// built-in mic turns into a 3-channel array while another app runs voice
/// processing on it) and writes zeros while reporting success, and for stereo
/// it keeps the first channel only.
final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let conversionQueue: DispatchQueue
    private let appendGate = AudioAppendGate()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    /// Non-nil when the input has more than one channel.
    private let downmixFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat
    private let captureID: UInt64
    private let diagnostics: AudioRecorderDiagnosticsState
    private var acceptsInput = true
    private var pcmData = Data()

    init(
        captureID: UInt64,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState
    ) throws {
        let converterInputFormat: AVAudioFormat
        if inputFormat.channelCount > 1 {
            guard inputFormat.commonFormat == .pcmFormatFloat32 else {
                throw AudioRecorderError.engineFailedToStart(
                    "unsupported \(inputFormat.channelCount)-channel input format \(inputFormat)"
                )
            }
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioRecorderError.engineFailedToStart("mono downmix format init failed")
            }
            downmixFormat = mono
            converterInputFormat = mono
        } else {
            downmixFormat = nil
            converterInputFormat = inputFormat
        }
        guard let converter = AVAudioConverter(from: converterInputFormat, to: outputFormat) else {
            throw AudioRecorderError.engineFailedToStart("converter init failed")
        }
        self.captureID = captureID
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.diagnostics = diagnostics
        conversionQueue = DispatchQueue(label: "WhisperKey.AudioRecorder.capture.\(captureID)", qos: .userInitiated)
    }

    var isDownmixing: Bool { downmixFormat != nil }

    func enqueue(
        buffer: AVAudioPCMBuffer,
        tapBufferID: UInt64,
        inputFrameLength: AVAudioFrameCount,
        enqueuedAtNanos: UInt64
    ) {
        guard isAcceptingInput else {
            diagnostics.recordAppendIgnored()
            return
        }
        guard appendGate.tryAcquire() else {
            diagnostics.recordAppendDropped()
            return
        }
        diagnostics.recordAppendScheduled()
        conversionQueue.async { [self] in
            defer { appendGate.release() }
            convert(
                buffer: buffer,
                tapBufferID: tapBufferID,
                inputFrameLength: inputFrameLength,
                enqueuedAtNanos: enqueuedAtNanos
            )
        }
    }

    /// Retires the pipeline without waiting for a conversion already executing
    /// on the CoreAudio queue. Its PCM snapshot becomes immutable to callers.
    func retireAndSnapshot() -> Data {
        lock.lock()
        acceptsInput = false
        let captured = pcmData
        lock.unlock()
        return captured
    }

    private var isAcceptingInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsInput
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        tapBufferID: UInt64,
        inputFrameLength: AVAudioFrameCount,
        enqueuedAtNanos: UInt64
    ) {
        guard isAcceptingInput else {
            diagnostics.recordAppendIgnored()
            return
        }

        let startedAtNanos = audioRecorderNowNanos()
        diagnostics.recordAppendStart(
            tapBufferID: tapBufferID,
            inputFrameLength: inputFrameLength,
            queueDelayNanos: startedAtNanos - enqueuedAtNanos
        )

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            diagnostics.recordOutputAllocationFailure(appendNanos: audioRecorderNowNanos() - startedAtNanos)
            return
        }

        let converterInput: AVAudioPCMBuffer
        if let downmixFormat {
            guard let mono = downmixToMono(buffer, monoFormat: downmixFormat) else {
                diagnostics.recordOutputAllocationFailure(appendNanos: audioRecorderNowNanos() - startedAtNanos)
                return
            }
            converterInput = mono
        } else {
            converterInput = buffer
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
            return converterInput
        }

        guard status != .error, error == nil else {
            let appendNanos = audioRecorderNowNanos() - startedAtNanos
            diagnostics.recordConverterFailure(appendNanos: appendNanos)
            recorderLog.error(
                "append: captureID=\(self.captureID, privacy: .public) tapBufferID=\(tapBufferID, privacy: .public) converter failed status=\(status.rawValue, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)"
            )
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0, let int16Channel = outputBuffer.int16ChannelData?.pointee else {
            diagnostics.recordEmptyOutputBuffer(appendNanos: audioRecorderNowNanos() - startedAtNanos)
            return
        }
        let byteCount = frameCount * MemoryLayout<Int16>.size * Int(outputFormat.channelCount)
        let converted = int16Channel.withMemoryRebound(to: UInt8.self, capacity: byteCount) {
            Data(bytes: $0, count: byteCount)
        }

        lock.lock()
        guard acceptsInput else {
            lock.unlock()
            diagnostics.recordAppendIgnored()
            return
        }
        pcmData.append(converted)
        let pcmByteCount = pcmData.count
        lock.unlock()
        diagnostics.recordAppendSuccess(
            outputFrameLength: outputBuffer.frameLength,
            appendNanos: audioRecorderNowNanos() - startedAtNanos,
            pcmBytes: pcmByteCount
        )
    }
}

public struct AudioRecorderDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let captureID: UInt64?
    public let engineHostID: UInt64?
    public let isRecording: Bool
    public let inputDeviceObjectID: UInt32?
    public let inputDeviceName: String?
    public let inputDeviceUID: String?
    public let inputSampleRate: Double?
    public let inputChannelCount: UInt32?
    public let inputCommonFormatRawValue: UInt?
    public let inputIsInterleaved: Bool?
    public let captureStartedAt: Date?
    public let engineStartedAt: Date?
    public let stopRequestedAt: Date?
    public let stopEnteredAt: Date?
    public let stopFinishedAt: Date?
    public let lastTapAt: Date?
    public let lastAppendStartedAt: Date?
    public let lastAppendFinishedAt: Date?
    public let tapBuffersReceived: UInt64
    public let appendTasksScheduled: UInt64
    public let appendTasksDropped: UInt64
    public let appendAttempts: UInt64
    public let appendIgnored: UInt64
    public let appendedBuffers: UInt64
    public let converterFailures: UInt64
    public let outputAllocationFailures: UInt64
    public let emptyOutputBuffers: UInt64
    public let tapInputFrames: UInt64
    public let appendInputFrames: UInt64
    public let outputFrames: UInt64
    public let pcmBytes: Int
    public let totalQueueDelayNanos: UInt64
    public let maxQueueDelayNanos: UInt64
    public let totalAppendNanos: UInt64
    public let maxAppendNanos: UInt64
    public let estimatedAppendBacklog: UInt64
    public let conversionInFlight: Bool
    public let inFlightTapBufferID: UInt64?
    public let conversionStartedAt: Date?
    public let stopReturnedBuffer: Bool?
    public let stopElapsedSeconds: TimeInterval?
    public let stopCapturedDurationSeconds: TimeInterval?
    public let captureStartTimeouts: UInt64
    public let lastCaptureStartTimeoutAt: Date?
    // Start phases of the current capture, in milliseconds. A phase that did
    // not run inside this capture's begin (the engine was already warm) is nil.
    public let inputNodeMillis: Double?
    public let installTapMillis: Double?
    public let prepareMillis: Double?
    public let engineStartMillis: Double?
    /// Time spent inside the engine host's begin work, queue wait excluded.
    public let beginTotalMillis: Double?
    public let reusedEngine: Bool?
}

/// Per-capture start timings measured by the engine host.
struct CaptureStartPhases: Sendable, Equatable {
    var inputNodeMillis: Double?
    var installTapMillis: Double?
    var prepareMillis: Double?
    var engineStartMillis: Double?
    var beginTotalMillis: Double?
    var reusedEngine: Bool?

    static func millis(since startNanos: UInt64, until endNanos: UInt64 = audioRecorderNowNanos()) -> Double {
        Double(endNanos &- startNanos) / 1_000_000
    }
}

final class AudioRecorderDiagnosticsState: @unchecked Sendable {
    private let lock = NSLock()

    private var captureID: UInt64?
    private var engineHostID: UInt64?
    private var isRecording = false
    private var inputDeviceObjectID: UInt32?
    private var inputDeviceName: String?
    private var inputDeviceUID: String?
    private var inputSampleRate: Double?
    private var inputChannelCount: UInt32?
    private var inputCommonFormatRawValue: UInt?
    private var inputIsInterleaved: Bool?
    private var captureStartedAt: Date?
    private var engineStartedAt: Date?
    private var stopRequestedAt: Date?
    private var stopEnteredAt: Date?
    private var stopFinishedAt: Date?
    private var lastTapAt: Date?
    private var lastAppendStartedAt: Date?
    private var lastAppendFinishedAt: Date?
    private var tapBuffersReceived: UInt64 = 0
    private var appendTasksScheduled: UInt64 = 0
    private var appendTasksDropped: UInt64 = 0
    private var appendAttempts: UInt64 = 0
    private var appendIgnored: UInt64 = 0
    private var appendedBuffers: UInt64 = 0
    private var converterFailures: UInt64 = 0
    private var outputAllocationFailures: UInt64 = 0
    private var emptyOutputBuffers: UInt64 = 0
    private var tapInputFrames: UInt64 = 0
    private var appendInputFrames: UInt64 = 0
    private var outputFrames: UInt64 = 0
    private var pcmBytes: Int = 0
    private var totalQueueDelayNanos: UInt64 = 0
    private var maxQueueDelayNanos: UInt64 = 0
    private var totalAppendNanos: UInt64 = 0
    private var maxAppendNanos: UInt64 = 0
    private var conversionInFlight = false
    private var inFlightTapBufferID: UInt64?
    private var conversionStartedAt: Date?
    private var stopReturnedBuffer: Bool?
    private var stopElapsedSeconds: TimeInterval?
    private var stopCapturedDurationSeconds: TimeInterval?
    private var captureStartTimeouts: UInt64 = 0
    private var lastCaptureStartTimeoutAt: Date?
    private var startPhases = CaptureStartPhases()

    func beginCapture(
        captureID: UInt64,
        engineHostID: UInt64,
        inputDevice: AudioInputDeviceSnapshot?,
        inputFormat: AVAudioFormat
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.captureID = captureID
        self.engineHostID = engineHostID
        self.isRecording = false
        self.inputDeviceObjectID = inputDevice.map { UInt32($0.objectID) }
        self.inputDeviceName = inputDevice?.name
        self.inputDeviceUID = inputDevice?.uid
        self.inputSampleRate = inputFormat.sampleRate
        self.inputChannelCount = inputFormat.channelCount
        self.inputCommonFormatRawValue = inputFormat.commonFormat.rawValue
        self.inputIsInterleaved = inputFormat.isInterleaved
        self.captureStartedAt = Date()
        self.engineStartedAt = nil
        self.stopRequestedAt = nil
        self.stopEnteredAt = nil
        self.stopFinishedAt = nil
        self.lastTapAt = nil
        self.lastAppendStartedAt = nil
        self.lastAppendFinishedAt = nil
        self.tapBuffersReceived = 0
        self.appendTasksScheduled = 0
        self.appendTasksDropped = 0
        self.appendAttempts = 0
        self.appendIgnored = 0
        self.appendedBuffers = 0
        self.converterFailures = 0
        self.outputAllocationFailures = 0
        self.emptyOutputBuffers = 0
        self.tapInputFrames = 0
        self.appendInputFrames = 0
        self.outputFrames = 0
        self.pcmBytes = 0
        self.totalQueueDelayNanos = 0
        self.maxQueueDelayNanos = 0
        self.totalAppendNanos = 0
        self.maxAppendNanos = 0
        self.conversionInFlight = false
        self.inFlightTapBufferID = nil
        self.conversionStartedAt = nil
        self.stopReturnedBuffer = nil
        self.stopElapsedSeconds = nil
        self.stopCapturedDurationSeconds = nil
        self.startPhases = CaptureStartPhases()
    }

    func recordStartPhases(_ phases: CaptureStartPhases) {
        lock.lock()
        startPhases = phases
        lock.unlock()
    }

    func recordCaptureStartTimeout() {
        lock.lock()
        defer { lock.unlock() }
        captureStartTimeouts += 1
        lastCaptureStartTimeoutAt = Date()
        isRecording = false
    }

    func recordEngineStarted() {
        lock.lock()
        engineStartedAt = Date()
        isRecording = true
        lock.unlock()
    }

    func recordStopRequested() {
        lock.lock()
        stopRequestedAt = stopRequestedAt ?? Date()
        lock.unlock()
    }

    func recordStopEntered() {
        lock.lock()
        stopEnteredAt = Date()
        lock.unlock()
    }

    func recordStopFinished(returnedBuffer: Bool, pcmBytes: Int, elapsed: TimeInterval, capturedDuration: TimeInterval) {
        lock.lock()
        isRecording = false
        stopFinishedAt = Date()
        stopReturnedBuffer = returnedBuffer
        stopElapsedSeconds = elapsed
        stopCapturedDurationSeconds = capturedDuration
        self.pcmBytes = pcmBytes
        lock.unlock()
    }

    func recordTap(inputFrameLength: AVAudioFrameCount) {
        lock.lock()
        tapBuffersReceived += 1
        tapInputFrames += UInt64(inputFrameLength)
        lastTapAt = Date()
        lock.unlock()
    }

    func recordAppendScheduled() {
        lock.lock()
        appendTasksScheduled += 1
        lock.unlock()
    }

    func recordAppendDropped() {
        lock.lock()
        appendTasksDropped += 1
        lock.unlock()
    }

    func recordAppendIgnored() {
        lock.lock()
        appendIgnored += 1
        clearInFlightConversionLocked()
        lock.unlock()
    }

    func recordAppendStart(tapBufferID: UInt64, inputFrameLength: AVAudioFrameCount, queueDelayNanos: UInt64) {
        lock.lock()
        appendAttempts += 1
        appendInputFrames += UInt64(inputFrameLength)
        totalQueueDelayNanos += queueDelayNanos
        maxQueueDelayNanos = max(maxQueueDelayNanos, queueDelayNanos)
        lastAppendStartedAt = Date()
        conversionInFlight = true
        inFlightTapBufferID = tapBufferID
        conversionStartedAt = lastAppendStartedAt
        lock.unlock()
    }

    func recordOutputAllocationFailure(appendNanos: UInt64) {
        lock.lock()
        outputAllocationFailures += 1
        recordAppendDurationLocked(appendNanos)
        lock.unlock()
    }

    func recordConverterFailure(appendNanos: UInt64) {
        lock.lock()
        converterFailures += 1
        recordAppendDurationLocked(appendNanos)
        lock.unlock()
    }

    func recordEmptyOutputBuffer(appendNanos: UInt64) {
        lock.lock()
        emptyOutputBuffers += 1
        recordAppendDurationLocked(appendNanos)
        lock.unlock()
    }

    func recordAppendSuccess(outputFrameLength: AVAudioFrameCount, appendNanos: UInt64, pcmBytes: Int) {
        lock.lock()
        appendedBuffers += 1
        outputFrames += UInt64(outputFrameLength)
        self.pcmBytes = pcmBytes
        recordAppendDurationLocked(appendNanos)
        lock.unlock()
    }

    func snapshot() -> AudioRecorderDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let completed = appendIgnored + appendedBuffers + converterFailures + outputAllocationFailures + emptyOutputBuffers
        let backlog = appendTasksScheduled > completed ? appendTasksScheduled - completed : 0
        return AudioRecorderDiagnosticsSnapshot(
            captureID: captureID,
            engineHostID: engineHostID,
            isRecording: isRecording,
            inputDeviceObjectID: inputDeviceObjectID,
            inputDeviceName: inputDeviceName,
            inputDeviceUID: inputDeviceUID,
            inputSampleRate: inputSampleRate,
            inputChannelCount: inputChannelCount,
            inputCommonFormatRawValue: inputCommonFormatRawValue,
            inputIsInterleaved: inputIsInterleaved,
            captureStartedAt: captureStartedAt,
            engineStartedAt: engineStartedAt,
            stopRequestedAt: stopRequestedAt,
            stopEnteredAt: stopEnteredAt,
            stopFinishedAt: stopFinishedAt,
            lastTapAt: lastTapAt,
            lastAppendStartedAt: lastAppendStartedAt,
            lastAppendFinishedAt: lastAppendFinishedAt,
            tapBuffersReceived: tapBuffersReceived,
            appendTasksScheduled: appendTasksScheduled,
            appendTasksDropped: appendTasksDropped,
            appendAttempts: appendAttempts,
            appendIgnored: appendIgnored,
            appendedBuffers: appendedBuffers,
            converterFailures: converterFailures,
            outputAllocationFailures: outputAllocationFailures,
            emptyOutputBuffers: emptyOutputBuffers,
            tapInputFrames: tapInputFrames,
            appendInputFrames: appendInputFrames,
            outputFrames: outputFrames,
            pcmBytes: pcmBytes,
            totalQueueDelayNanos: totalQueueDelayNanos,
            maxQueueDelayNanos: maxQueueDelayNanos,
            totalAppendNanos: totalAppendNanos,
            maxAppendNanos: maxAppendNanos,
            estimatedAppendBacklog: backlog,
            conversionInFlight: conversionInFlight,
            inFlightTapBufferID: inFlightTapBufferID,
            conversionStartedAt: conversionStartedAt,
            stopReturnedBuffer: stopReturnedBuffer,
            stopElapsedSeconds: stopElapsedSeconds,
            stopCapturedDurationSeconds: stopCapturedDurationSeconds,
            captureStartTimeouts: captureStartTimeouts,
            lastCaptureStartTimeoutAt: lastCaptureStartTimeoutAt,
            inputNodeMillis: startPhases.inputNodeMillis,
            installTapMillis: startPhases.installTapMillis,
            prepareMillis: startPhases.prepareMillis,
            engineStartMillis: startPhases.engineStartMillis,
            beginTotalMillis: startPhases.beginTotalMillis,
            reusedEngine: startPhases.reusedEngine
        )
    }

    private func recordAppendDurationLocked(_ nanos: UInt64) {
        totalAppendNanos += nanos
        maxAppendNanos = max(maxAppendNanos, nanos)
        lastAppendFinishedAt = Date()
        clearInFlightConversionLocked()
    }

    private func clearInFlightConversionLocked() {
        conversionInFlight = false
        inFlightTapBufferID = nil
        conversionStartedAt = nil
    }
}

struct AudioInputDeviceSnapshot: Equatable, Sendable {
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

    public var isDigitalSilence: Bool {
        !samples.isEmpty && samples.allSatisfy { $0 == 0 }
    }
}

public enum AudioRecorderError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case engineFailedToStart(String)
    case alreadyRecording
    /// The audio engine did not report a started capture within the start
    /// deadline. The associated value is the deadline in seconds.
    case engineStartTimedOut(TimeInterval)
}

/// The input device's nominal sample rate and input channel count, read
/// straight from CoreAudio. Read again before reusing an engine, it says
/// whether the hardware changed since the engine was built.
///
/// It is compared with itself, never with the engine's format: with a
/// different output device, AVAudioEngine runs its input at the output's rate
/// (a 48 kHz MacBook mic shows up as 44.1 kHz next to 44.1 kHz speakers).
struct AudioInputHardwareFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32

    var logDescription: String {
        "sampleRate=\(sampleRate) channelCount=\(channelCount)"
    }

    static func current(deviceID: AudioObjectID) -> AudioInputHardwareFormat? {
        guard
            let sampleRate = nominalSampleRate(deviceID: deviceID),
            let channelCount = inputChannelCount(deviceID: deviceID)
        else {
            return nil
        }
        return AudioInputHardwareFormat(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func nominalSampleRate(deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else {
            recorderLog.error("nominalSampleRate: deviceID=\(deviceID, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
        return rate
    }

    private static func inputChannelCount(deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size > 0 else {
            recorderLog.error("inputChannelCount: deviceID=\(deviceID, privacy: .public) size status=\(status, privacy: .public)")
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw)
        guard status == noErr else {
            recorderLog.error("inputChannelCount: deviceID=\(deviceID, privacy: .public) status=\(status, privacy: .public)")
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }
}

/// The default output device and its nominal sample rate. AVAudioEngine's
/// input format follows the output device on macOS, so a change here makes a
/// warm engine stale as surely as an input change does.
struct AudioOutputDeviceSnapshot: Equatable, Sendable {
    let objectID: AudioObjectID
    let sampleRate: Double?

    var logDescription: String {
        "id=\(objectID) sampleRate=\(sampleRate.map { String($0) } ?? "nil")"
    }

    static func currentDefault() -> AudioOutputDeviceSnapshot? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return AudioOutputDeviceSnapshot(
            objectID: deviceID,
            sampleRate: AudioInputHardwareFormat.nominalSampleRate(deviceID: deviceID)
        )
    }
}

/// Everything a successful capture start hands back to the `AudioRecorder`
/// actor. Not `Sendable` by construction: it carries CoreAudio objects that
/// only the recorder and the capture's own pipeline touch.
struct CaptureStartResult: @unchecked Sendable {
    let pipeline: CapturePipeline
    let inputDevice: AudioInputDeviceSnapshot?
    let inputFormat: AVAudioFormat
}

/// Why an engine host's `begin` did not start a capture.
enum CaptureBeginError: Error, Equatable, Sendable {
    /// The host's engine was built for an input that no longer matches the
    /// hardware. The recorder retires it and builds one fresh host.
    case staleHost(String)
    case recorder(AudioRecorderError)
}

/// Owns one `AVAudioEngine` and performs every CoreAudio-touching operation on
/// its own serial queue.
///
/// A CoreAudio call that never returns — `AVAudioEngine.inputNode` waiting on
/// `coreaudiod` for the hardware format is the observed case — strands this
/// host and its queue. It must never strand the `AudioRecorder` actor, which
/// still has to answer `stop()` and start a later capture.
///
/// A host outlives one capture while its input stays the same: building the
/// engine (input node, tap, `prepare()`) is most of the start latency.
protocol CaptureEngineHosting: AnyObject, Sendable {
    var hostID: UInt64 { get }

    /// Builds the engine ahead of a capture without starting it. Returns at
    /// once; the work runs on the host's queue. Idempotent.
    func warm()

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    )

    /// Ends a capture normally and keeps the host for the next one: detaches
    /// the capture, then stops and re-prepares the engine off the actor.
    func endCapture()

    /// Marks the host unusable and tears the engine down off the actor.
    /// Safe to call more than once, and safe to call while `begin` is stuck.
    func retire()
}

/// Resolves to whichever settles first: the engine host's completion or the
/// start deadline. Whoever loses the race is dropped, never resumed twice.
private final class StartResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<CaptureStartResult, CaptureBeginError>, Never>?
    private var pending: Result<CaptureStartResult, CaptureBeginError>?
    private var isSettled = false

    func settle(_ result: Result<CaptureStartResult, CaptureBeginError>) {
        lock.lock()
        guard !isSettled else {
            lock.unlock()
            return
        }
        isSettled = true
        if let waiting = continuation {
            continuation = nil
            lock.unlock()
            waiting.resume(returning: result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    func value() async -> Result<CaptureStartResult, CaptureBeginError> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let ready = pending {
                pending = nil
                lock.unlock()
                continuation.resume(returning: ready)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// The one tap a host installs forwards each buffer to whichever capture is
/// attached. Between captures nothing is attached and buffers are dropped.
private final class TapForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: CapturePipeline?
    private var diagnostics: AudioRecorderDiagnosticsState?
    private var tapBufferSequence: UInt64 = 0

    func attach(_ pipeline: CapturePipeline, diagnostics: AudioRecorderDiagnosticsState) {
        lock.lock()
        self.pipeline = pipeline
        self.diagnostics = diagnostics
        tapBufferSequence = 0
        lock.unlock()
    }

    @discardableResult
    func detach() -> CapturePipeline? {
        lock.lock()
        defer { lock.unlock() }
        let detached = pipeline
        pipeline = nil
        diagnostics = nil
        return detached
    }

    func forward(_ buffer: AVAudioPCMBuffer) {
        let enqueuedAtNanos = audioRecorderNowNanos()
        lock.lock()
        guard let pipeline, let diagnostics else {
            lock.unlock()
            return
        }
        tapBufferSequence += 1
        let tapBufferID = tapBufferSequence
        lock.unlock()

        let inputFrameLength = buffer.frameLength
        diagnostics.recordTap(inputFrameLength: inputFrameLength)
        guard let copiedBuffer = copyPCMBuffer(buffer) else {
            diagnostics.recordOutputAllocationFailure(appendNanos: 0)
            return
        }
        pipeline.enqueue(
            buffer: copiedBuffer,
            tapBufferID: tapBufferID,
            inputFrameLength: inputFrameLength,
            enqueuedAtNanos: enqueuedAtNanos
        )
    }
}

final class CaptureEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64

    private let queue: DispatchQueue
    private let forwarder = TapForwarder()
    private let lock = NSLock()
    private var isRetired = false
    private var configurationChanged = false

    /// What the engine was built for. Touched only from `queue`.
    private struct WarmState {
        let inputDevice: AudioInputDeviceSnapshot?
        let inputHardware: AudioInputHardwareFormat?
        let outputDevice: AudioOutputDeviceSnapshot?
        let inputFormat: AVAudioFormat
    }

    // Touched only from `queue`.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var didInstallTap = false
    private var warmState: WarmState?
    private var warmFailure: String?

    init(hostID: UInt64) {
        self.hostID = hostID
        queue = DispatchQueue(label: "WhisperKey.AudioRecorder.engine.\(hostID)", qos: .userInitiated)
    }

    func warm() {
        queue.async { [self] in
            guard !isRetiredNow, engine == nil, warmFailure == nil else { return }
            var phases = CaptureStartPhases()
            do {
                try performWarm(phases: &phases)
                recorderLog.info(
                    "prewarm: hostID=\(self.hostID, privacy: .public) warm inputNodeMs=\(phases.inputNodeMillis ?? -1, privacy: .public) installTapMs=\(phases.installTapMillis ?? -1, privacy: .public) prepareMs=\(phases.prepareMillis ?? -1, privacy: .public)"
                )
            } catch {
                // A half-built engine is not reused: `begin` reports the host
                // stale and the recorder builds a fresh one.
                warmFailure = String(describing: error)
                recorderLog.error("prewarm: hostID=\(self.hostID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {
        queue.async { [self] in
            let result: Result<CaptureStartResult, CaptureBeginError>
            do {
                let started = try performBegin(
                    captureID: captureID,
                    outputFormat: outputFormat,
                    diagnostics: diagnostics,
                    previousInputDevice: previousInputDevice
                )
                result = .success(started)
            } catch let error as CaptureBeginError {
                result = .failure(error)
            } catch let error as AudioRecorderError {
                result = .failure(.recorder(error))
            } catch {
                result = .failure(.recorder(.engineFailedToStart(error.localizedDescription)))
            }

            // The recorder may have given up on this host while a CoreAudio
            // call was stuck. A late success must tear itself down instead of
            // recording into a capture nobody is waiting for.
            guard !isRetiredNow else {
                recorderLog.error(
                    "beginCapture: captureID=\(captureID, privacy: .public) hostID=\(self.hostID, privacy: .public) completed after the host was retired; tearing down"
                )
                teardown()
                completion(.failure(.recorder(.engineFailedToStart("engine host retired before start completed"))))
                return
            }
            completion(result)
        }
    }

    func endCapture() {
        // Detached at once, under a short lock: no buffer reaches the finished
        // capture even while the queue is still busy.
        forwarder.detach()
        queue.async { [self] in
            guard !isRetiredNow, let engine else { return }
            engine.stop()
            // Re-prepared so the next start is only `engine.start()`. A host
            // whose configuration changed is stale anyway; leave it alone.
            guard !configurationChangedNow else { return }
            engine.prepare()
        }
    }

    func retire() {
        lock.lock()
        let wasRetired = isRetired
        isRetired = true
        lock.unlock()
        guard !wasRetired else { return }
        queue.async { [self] in teardown() }
    }

    private var isRetiredNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRetired
    }

    private var configurationChangedNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configurationChanged
    }

    private func markConfigurationChanged() {
        lock.lock()
        configurationChanged = true
        lock.unlock()
        recorderLog.notice("engine host hostID=\(self.hostID, privacy: .public) received AVAudioEngineConfigurationChange; it will not be reused")
    }

    /// Builds the engine: input node, one persistent tap, `prepare()`. Never
    /// starts it, so the input device does not run until a capture begins.
    private func performWarm(phases: inout CaptureStartPhases) throws {
        let inputDevice = AudioInputDeviceSnapshot.currentDefault()
        let inputHardware = inputDevice.flatMap { AudioInputHardwareFormat.current(deviceID: $0.objectID) }
        let outputDevice = AudioOutputDeviceSnapshot.currentDefault()
        let engine = AVAudioEngine()
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.markConfigurationChanged()
        }

        // A fresh engine reads the hardware format on first access to its
        // input node and caches it for its lifetime. Reusing an engine across
        // a device switch made installTap throw an Obj-C exception on format
        // mismatch, which crashed the app. So the tap goes in exactly once,
        // here, on the format just read, and every reuse first checks that
        // the hardware still is what this engine was built for.
        let inputNodeStartedAt = audioRecorderNowNanos()
        let input = engine.inputNode
        phases.inputNodeMillis = CaptureStartPhases.millis(since: inputNodeStartedAt)
        let inputFormat = input.outputFormat(forBus: 0)
        recorderLog.info(
            "warm: hostID=\(self.hostID, privacy: .public) defaultInput=\(inputDevice?.logDescription ?? "nil", privacy: .public) inputHardware=\(inputHardware?.logDescription ?? "nil", privacy: .public) defaultOutput=\(outputDevice?.logDescription ?? "nil", privacy: .public) inputFormat sampleRate=\(inputFormat.sampleRate, privacy: .public) channelCount=\(inputFormat.channelCount, privacy: .public) commonFormat=\(inputFormat.commonFormat.rawValue, privacy: .public) interleaved=\(inputFormat.isInterleaved, privacy: .public)"
        )

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            recorderLog.error("warm: hostID=\(self.hostID, privacy: .public) invalid input format \(String(describing: inputFormat), privacy: .public)")
            throw AudioRecorderError.engineFailedToStart("invalid input format \(inputFormat)")
        }

        let installTapStartedAt = audioRecorderNowNanos()
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [forwarder] buffer, _ in
            forwarder.forward(buffer)
        }
        didInstallTap = true
        phases.installTapMillis = CaptureStartPhases.millis(since: installTapStartedAt)

        let prepareStartedAt = audioRecorderNowNanos()
        engine.prepare()
        phases.prepareMillis = CaptureStartPhases.millis(since: prepareStartedAt)

        warmState = WarmState(
            inputDevice: inputDevice,
            inputHardware: inputHardware,
            outputDevice: outputDevice,
            inputFormat: inputFormat
        )
    }

    /// Why a warm engine no longer describes the hardware, or nil if it does.
    /// Runs on `queue`: these CoreAudio reads can hang, and the recorder's
    /// start deadline covers this queue, never the actor.
    private func stalenessReason(of warm: WarmState) -> String? {
        if configurationChangedNow {
            return "the engine configuration changed"
        }
        guard let builtFor = warm.inputDevice else {
            return "no default input device was known when the engine was built"
        }
        let current = AudioInputDeviceSnapshot.currentDefault()
        guard current == builtFor else {
            return "the default input changed from \(builtFor.logDescription) to \(current?.logDescription ?? "nil")"
        }
        guard
            let builtForHardware = warm.inputHardware,
            let hardware = AudioInputHardwareFormat.current(deviceID: builtFor.objectID)
        else {
            return "the input hardware format could not be read"
        }
        guard hardware == builtForHardware else {
            return "the input hardware changed from \(builtForHardware.logDescription) to \(hardware.logDescription)"
        }
        let output = AudioOutputDeviceSnapshot.currentDefault()
        guard output == warm.outputDevice else {
            return "the default output changed from \(warm.outputDevice?.logDescription ?? "nil") to \(output?.logDescription ?? "nil")"
        }
        return nil
    }

    private func performBegin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?
    ) throws -> CaptureStartResult {
        let beginStartedAt = audioRecorderNowNanos()
        if let warmFailure {
            throw CaptureBeginError.staleHost("an earlier warm-up failed: \(warmFailure)")
        }

        // `reusedEngine` is true when the engine was built before this begin,
        // by `warm()` or by an earlier capture.
        var phases = CaptureStartPhases(reusedEngine: warmState != nil)
        if let warm = warmState {
            if let reason = stalenessReason(of: warm) {
                recorderLog.notice(
                    "beginCapture: captureID=\(captureID, privacy: .public) hostID=\(self.hostID, privacy: .public) stale: \(reason, privacy: .public)"
                )
                throw CaptureBeginError.staleHost(reason)
            }
        } else {
            // Just built from the current hardware: nothing to be stale against.
            try performWarm(phases: &phases)
        }
        guard let warm = warmState, let engine else {
            throw AudioRecorderError.engineFailedToStart("engine host is not warm")
        }

        let inputDevice = warm.inputDevice
        let inputFormat = warm.inputFormat
        let didInputDeviceChange = previousInputDevice.map { $0 != inputDevice } ?? false
        recorderLog.info(
            "beginCapture: captureID=\(captureID, privacy: .public) hostID=\(self.hostID, privacy: .public) reusedEngine=\(phases.reusedEngine ?? false, privacy: .public) defaultInput=\(inputDevice?.logDescription ?? "nil", privacy: .public) inputDeviceChangedSincePrevious=\(didInputDeviceChange, privacy: .public)"
        )
        diagnostics.beginCapture(
            captureID: captureID,
            engineHostID: hostID,
            inputDevice: inputDevice,
            inputFormat: inputFormat
        )

        let pipeline: CapturePipeline
        do {
            pipeline = try CapturePipeline(
                captureID: captureID,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                diagnostics: diagnostics
            )
        } catch {
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) pipeline init failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        if pipeline.isDownmixing {
            recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) downmixing \(inputFormat.channelCount, privacy: .public) input channels to mono")
        }
        forwarder.attach(pipeline, diagnostics: diagnostics)

        let engineStartStartedAt = audioRecorderNowNanos()
        do {
            try engine.start()
        } catch {
            teardown()
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) engine.start failed: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

        phases.engineStartMillis = CaptureStartPhases.millis(since: engineStartStartedAt)
        phases.beginTotalMillis = CaptureStartPhases.millis(since: beginStartedAt)
        diagnostics.recordStartPhases(phases)
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) engine started")
        return CaptureStartResult(
            pipeline: pipeline,
            inputDevice: inputDevice,
            inputFormat: inputFormat
        )
    }

    /// Idempotent. Runs on `queue`, so it is ordered behind any `begin` work
    /// that is still stuck in CoreAudio.
    private func teardown() {
        if let pipeline = forwarder.detach() {
            _ = pipeline.retireAndSnapshot()
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        warmState = nil
        guard let engine else { return }
        if didInstallTap {
            didInstallTap = false
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
    }
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
    /// How long `start()` waits for the audio engine before giving up. A
    /// wedged `coreaudiod` can make the first CoreAudio call of a capture
    /// never return; the user gets an error instead of a dead recorder.
    public static let defaultStartTimeout: TimeInterval = 3

    public let maxDuration: TimeInterval
    let startTimeout: TimeInterval
    private nonisolated let diagnostics = AudioRecorderDiagnosticsState()
    private let engineHostFactory: @Sendable (UInt64) -> CaptureEngineHosting
    private let permissionCheckOverride: (@Sendable () async throws -> Void)?
    private let isMicrophoneAuthorized: @Sendable () -> Bool

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

    private var activePipeline: CapturePipeline?
    /// The engine host in use: recording through it, or kept warm after
    /// `prewarm()` or a normal `stop()` so the next start reuses its engine.
    private var host: CaptureEngineHosting?
    private var isRecording = false
    private var isStarting = false
    private var startTime: Date?
    private var activeCaptureID: UInt64?
    private var nextCaptureID: UInt64 = 1
    private var nextEngineHostID: UInt64 = 1
    private var activeInputDevice: AudioInputDeviceSnapshot?
    private var lastInputDevice: AudioInputDeviceSnapshot?
    private var maxDurationTask: Task<Void, Never>?
    private var onMaxDurationReached: (@Sendable () async -> Void)?

    public init(maxDuration: TimeInterval = AudioRecorder.defaultMaxDuration) {
        self.maxDuration = maxDuration
        self.startTimeout = AudioRecorder.defaultStartTimeout
        self.engineHostFactory = { CaptureEngineHost(hostID: $0) }
        self.permissionCheckOverride = nil
        self.isMicrophoneAuthorized = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    }

    /// Test seam: lets a test drive a host that stalls, completes late, or
    /// succeeds without touching real audio hardware.
    init(
        maxDuration: TimeInterval,
        startTimeout: TimeInterval,
        engineHostFactory: @escaping @Sendable (UInt64) -> CaptureEngineHosting,
        permissionCheck: @escaping @Sendable () async throws -> Void,
        isMicrophoneAuthorized: @escaping @Sendable () -> Bool = { true }
    ) {
        self.maxDuration = maxDuration
        self.startTimeout = startTimeout
        self.engineHostFactory = engineHostFactory
        self.permissionCheckOverride = permissionCheck
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
    }

    /// Registers a callback fired when `maxDuration` is reached.
    /// The handler is responsible for invoking the manual-stop flow.
    public func setOnMaxDurationReached(_ handler: (@Sendable () async -> Void)?) {
        onMaxDurationReached = handler
    }

    public var sampleRate: Double { outputFormat.sampleRate }
    public var channelCount: UInt32 { outputFormat.channelCount }

    public nonisolated func diagnosticsSnapshot() -> AudioRecorderDiagnosticsSnapshot {
        diagnostics.snapshot()
    }

    public nonisolated func recordStopRequestedForDiagnostics() {
        diagnostics.recordStopRequested()
    }

    /// Builds the engine ahead of the next `start()` without starting it, so
    /// that start costs only `engine.start()`. A no-op unless microphone
    /// access is already granted (it never prompts) and no capture is running
    /// or starting. Returns at once: the CoreAudio work runs on the host's queue.
    public func prewarm() {
        guard !isRecording, !isStarting, host == nil else { return }
        guard isMicrophoneAuthorized() else { return }
        let host = makeHost()
        recorderLog.info("prewarm: building engine host hostID=\(host.hostID, privacy: .public)")
        host.warm()
    }

    public func start() async throws {
        guard !isRecording, !isStarting else { throw AudioRecorderError.alreadyRecording }
        try await ensureMicrophonePermission()
        guard !isRecording, !isStarting else { throw AudioRecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }

        let captureID = nextCaptureID
        nextCaptureID += 1
        // One deadline for the whole start, a retry on a fresh host included.
        let deadlineNanos = audioRecorderNowNanos() + UInt64(startTimeout * 1_000_000_000)
        var replacedStaleHost = false

        while true {
            let host = self.host ?? makeHost()
            let outcome = await begin(on: host, captureID: captureID, deadlineNanos: deadlineNanos)

            switch outcome {
            case .success(let started):
                activePipeline = started.pipeline
                isRecording = true
                startTime = Date()
                activeCaptureID = captureID
                activeInputDevice = started.inputDevice
                lastInputDevice = started.inputDevice
                diagnostics.recordEngineStarted()
                scheduleMaxDurationTask()
                return
            case .failure(.staleHost(let reason)) where !replacedStaleHost:
                replacedStaleHost = true
                recorderLog.notice(
                    "start: captureID=\(captureID, privacy: .public) hostID=\(host.hostID, privacy: .public) is stale (\(reason, privacy: .public)); retiring it and building a fresh host"
                )
                retire(host)
            case .failure(let failure):
                retire(host)
                let error: AudioRecorderError
                switch failure {
                case .recorder(let recorderError):
                    error = recorderError
                case .staleHost(let reason):
                    error = .engineFailedToStart("the audio input changed while starting: \(reason)")
                }
                if case .engineStartTimedOut(let seconds) = error {
                    diagnostics.recordCaptureStartTimeout()
                    recorderLog.error(
                        "start: captureID=\(captureID, privacy: .public) hostID=\(host.hostID, privacy: .public) timed out after \(seconds, privacy: .public)s; retiring engine host"
                    )
                }
                throw error
            }
        }
    }

    private func makeHost() -> CaptureEngineHosting {
        let hostID = nextEngineHostID
        nextEngineHostID += 1
        let host = engineHostFactory(hostID)
        self.host = host
        return host
    }

    private func retire(_ host: CaptureEngineHosting) {
        host.retire()
        if self.host === host {
            self.host = nil
        }
    }

    private func begin(
        on host: CaptureEngineHosting,
        captureID: UInt64,
        deadlineNanos: UInt64
    ) async -> Result<CaptureStartResult, CaptureBeginError> {
        let deadline = startTimeout
        let now = audioRecorderNowNanos()
        guard deadlineNanos > now else {
            return .failure(.recorder(.engineStartTimedOut(deadline)))
        }
        let remainingNanos = deadlineNanos - now

        let box = StartResultBox()
        host.begin(
            captureID: captureID,
            outputFormat: outputFormat,
            diagnostics: diagnostics,
            previousInputDevice: lastInputDevice
        ) { result in
            box.settle(result)
        }

        let timeoutTask = Task { [box] in
            try? await Task.sleep(nanoseconds: remainingNanos)
            guard !Task.isCancelled else { return }
            box.settle(.failure(.recorder(.engineStartTimedOut(deadline))))
        }
        // Awaiting the box frees the actor's executor: a CoreAudio call stuck
        // inside the host cannot block a later `stop()` or `start()`.
        let outcome = await box.value()
        timeoutTask.cancel()
        return outcome
    }

    public func stop() -> AudioBuffer? {
        diagnostics.recordStopEntered()
        guard isRecording else {
            diagnostics.recordStopFinished(returnedBuffer: false, pcmBytes: 0, elapsed: 0, capturedDuration: 0)
            return nil
        }
        isRecording = false

        maxDurationTask?.cancel()
        maxDurationTask = nil

        // Retire the capture before the engine: the PCM snapshot is taken
        // under a short lock, while stopping the engine is CoreAudio work
        // that the host performs on its own queue. The host is kept, warm,
        // for the next start.
        let captured = activePipeline?.retireAndSnapshot() ?? Data()
        host?.endCapture()
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let capturedDuration = capturedDuration(byteCount: captured.count)
        let expectedBytes = expectedByteCount(duration: elapsed)
        let capturedByteDelta = captured.count - expectedBytes
        let captureDurationRatio = elapsed > 0 ? capturedDuration / elapsed : 0
        recorderLog.info(
            "stop: captureID=\(self.activeCaptureID ?? 0, privacy: .public) elapsed=\(elapsed, privacy: .public) capturedBytes=\(captured.count, privacy: .public) expectedBytes=\(expectedBytes, privacy: .public) capturedByteDelta=\(capturedByteDelta, privacy: .public) capturedDuration=\(capturedDuration, privacy: .public) captureDurationRatio=\(captureDurationRatio, privacy: .public) inputDevice=\(self.activeInputDevice?.logDescription ?? "nil", privacy: .public)"
        )
        let returnedBuffer = elapsed >= Self.minDuration && !captured.isEmpty
        diagnostics.recordStopFinished(
            returnedBuffer: returnedBuffer,
            pcmBytes: captured.count,
            elapsed: elapsed,
            capturedDuration: capturedDuration
        )
        startTime = nil
        activePipeline = nil
        activeCaptureID = nil
        activeInputDevice = nil

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
        if let override = permissionCheckOverride {
            try await override()
            return
        }
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

    private func scheduleMaxDurationTask() {
        let duration = maxDuration
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.handleMaxDurationReached()
        }
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
