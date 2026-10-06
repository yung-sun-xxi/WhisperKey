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

/// Owns the conversion work for exactly one microphone capture.
///
/// CoreAudio conversion is intentionally kept off `AudioRecorder`'s actor
/// executor. A converter that stops returning may strand this pipeline, but it
/// must not strand the controls for the current or a later recording.
final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let conversionQueue: DispatchQueue
    private let appendGate = AudioAppendGate()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let captureID: UInt64
    private let diagnostics: AudioRecorderDiagnosticsState
    private var acceptsInput = true
    private var pcmData = Data()

    init(
        captureID: UInt64,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState
    ) {
        self.captureID = captureID
        self.converter = converter
        self.outputFormat = outputFormat
        self.diagnostics = diagnostics
        conversionQueue = DispatchQueue(label: "WhisperKey.AudioRecorder.capture.\(captureID)", qos: .userInitiated)
    }

    func enqueue(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
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
                inputFormat: inputFormat,
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
        inputFormat: AVAudioFormat,
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
            lastCaptureStartTimeoutAt: lastCaptureStartTimeoutAt
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

/// Everything a successful capture start hands back to the `AudioRecorder`
/// actor. Not `Sendable` by construction: it carries CoreAudio objects that
/// only the recorder and the capture's own pipeline touch.
struct CaptureStartResult: @unchecked Sendable {
    let pipeline: CapturePipeline
    let inputDevice: AudioInputDeviceSnapshot?
    let inputFormat: AVAudioFormat
}

/// Owns one `AVAudioEngine` and performs every CoreAudio-touching operation on
/// its own serial queue.
///
/// A CoreAudio call that never returns — `AVAudioEngine.inputNode` waiting on
/// `coreaudiod` for the hardware format is the observed case — strands this
/// host and its queue. It must never strand the `AudioRecorder` actor, which
/// still has to answer `stop()` and start a later capture.
protocol CaptureEngineHosting: AnyObject, Sendable {
    var hostID: UInt64 { get }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    )

    /// Marks the host unusable and tears the engine down off the actor.
    /// Safe to call more than once, and safe to call while `begin` is stuck.
    func retire()
}

/// Resolves to whichever settles first: the engine host's completion or the
/// start deadline. Whoever loses the race is dropped, never resumed twice.
private final class StartResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<CaptureStartResult, AudioRecorderError>, Never>?
    private var pending: Result<CaptureStartResult, AudioRecorderError>?
    private var isSettled = false

    func settle(_ result: Result<CaptureStartResult, AudioRecorderError>) {
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

    func value() async -> Result<CaptureStartResult, AudioRecorderError> {
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

final class CaptureEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64

    private let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var isRetired = false

    // Touched only from `queue`.
    private var installedPipeline: CapturePipeline?
    private var didInstallTap = false

    init(hostID: UInt64) {
        self.hostID = hostID
        queue = DispatchQueue(label: "WhisperKey.AudioRecorder.engine.\(hostID)", qos: .userInitiated)
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {
        queue.async { [self] in
            let result: Result<CaptureStartResult, AudioRecorderError>
            do {
                let started = try performBegin(
                    captureID: captureID,
                    outputFormat: outputFormat,
                    diagnostics: diagnostics,
                    previousInputDevice: previousInputDevice
                )
                result = .success(started)
            } catch let error as AudioRecorderError {
                result = .failure(error)
            } catch {
                result = .failure(.engineFailedToStart(error.localizedDescription))
            }

            // The recorder may have given up on this host while a CoreAudio
            // call was stuck. A late success must tear itself down instead of
            // recording into a capture nobody is waiting for.
            guard !isRetiredNow else {
                recorderLog.error(
                    "beginCapture: captureID=\(captureID, privacy: .public) hostID=\(self.hostID, privacy: .public) completed after the host was retired; tearing down"
                )
                teardown()
                completion(.failure(.engineFailedToStart("engine host retired before start completed")))
                return
            }
            completion(result)
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

    private func performBegin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?
    ) throws -> CaptureStartResult {
        let inputDevice = AudioInputDeviceSnapshot.currentDefault()
        let didInputDeviceChange = previousInputDevice.map { $0 != inputDevice } ?? false

        recorderLog.info(
            "beginCapture: captureID=\(captureID, privacy: .public) hostID=\(self.hostID, privacy: .public) defaultInput=\(inputDevice?.logDescription ?? "nil", privacy: .public) inputDeviceChangedSincePrevious=\(didInputDeviceChange, privacy: .public)"
        )

        // Each capture gets its own engine (this host owns exactly one) so the
        // input node's cached format matches the current hardware. AVAudioEngine
        // caches the format from its first activation; reusing one across a
        // device switch makes installTap throw an Obj-C exception on format
        // mismatch, which crashes the app.
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        diagnostics.beginCapture(
            captureID: captureID,
            engineHostID: hostID,
            inputDevice: inputDevice,
            inputFormat: inputFormat
        )
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

        let pipeline = CapturePipeline(
            captureID: captureID,
            converter: converter,
            outputFormat: outputFormat,
            diagnostics: diagnostics
        )
        installedPipeline = pipeline

        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) installing input tap")
        var tapBufferSequence: UInt64 = 0
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            tapBufferSequence += 1
            let tapBufferID = tapBufferSequence
            let enqueuedAtNanos = audioRecorderNowNanos()
            let inputFrameLength = buffer.frameLength
            diagnostics.recordTap(inputFrameLength: inputFrameLength)
            guard let copiedBuffer = copyPCMBuffer(buffer) else {
                diagnostics.recordOutputAllocationFailure(appendNanos: 0)
                return
            }
            pipeline.enqueue(
                buffer: copiedBuffer,
                inputFormat: inputFormat,
                tapBufferID: tapBufferID,
                inputFrameLength: inputFrameLength,
                enqueuedAtNanos: enqueuedAtNanos
            )
        }
        didInstallTap = true
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) input tap installed")

        engine.prepare()
        recorderLog.info("beginCapture: captureID=\(captureID, privacy: .public) engine prepared; starting")
        do {
            try engine.start()
        } catch {
            teardown()
            recorderLog.error("beginCapture: captureID=\(captureID, privacy: .public) engine.start failed: \(error.localizedDescription, privacy: .public)")
            throw AudioRecorderError.engineFailedToStart(error.localizedDescription)
        }

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
        if let pipeline = installedPipeline {
            _ = pipeline.retireAndSnapshot()
            installedPipeline = nil
        }
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
    private var activeHost: CaptureEngineHosting?
    private var isRecording = false
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
    }

    /// Test seam: lets a test drive a host that stalls, completes late, or
    /// succeeds without touching real audio hardware.
    init(
        maxDuration: TimeInterval,
        startTimeout: TimeInterval,
        engineHostFactory: @escaping @Sendable (UInt64) -> CaptureEngineHosting,
        permissionCheck: @escaping @Sendable () async throws -> Void
    ) {
        self.maxDuration = maxDuration
        self.startTimeout = startTimeout
        self.engineHostFactory = engineHostFactory
        self.permissionCheckOverride = permissionCheck
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

    public func start() async throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }
        try await ensureMicrophonePermission()

        let captureID = nextCaptureID
        nextCaptureID += 1
        let hostID = nextEngineHostID
        nextEngineHostID += 1

        let host = engineHostFactory(hostID)
        let box = StartResultBox()
        host.begin(
            captureID: captureID,
            outputFormat: outputFormat,
            diagnostics: diagnostics,
            previousInputDevice: lastInputDevice
        ) { result in
            box.settle(result)
        }

        let deadline = startTimeout
        let timeoutTask = Task { [box] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            box.settle(.failure(.engineStartTimedOut(deadline)))
        }
        // Awaiting the box frees the actor's executor: a CoreAudio call stuck
        // inside the host cannot block a later `stop()` or `start()`.
        let outcome = await box.value()
        timeoutTask.cancel()

        switch outcome {
        case .success(let started):
            activeHost = host
            activePipeline = started.pipeline
            isRecording = true
            startTime = Date()
            activeCaptureID = captureID
            activeInputDevice = started.inputDevice
            lastInputDevice = started.inputDevice
            diagnostics.recordEngineStarted()
            scheduleMaxDurationTask()
        case .failure(let error):
            host.retire()
            if case .engineStartTimedOut(let seconds) = error {
                diagnostics.recordCaptureStartTimeout()
                recorderLog.error(
                    "start: captureID=\(captureID, privacy: .public) hostID=\(hostID, privacy: .public) timed out after \(seconds, privacy: .public)s; retiring engine host"
                )
            }
            throw error
        }
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
        // under a short lock, while tearing the engine down is CoreAudio work
        // that the host performs on its own queue.
        let captured = activePipeline?.retireAndSnapshot() ?? Data()
        activeHost?.retire()
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
        activeHost = nil
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
