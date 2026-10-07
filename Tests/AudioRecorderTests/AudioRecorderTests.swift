import AVFoundation
import XCTest
@testable import AudioRecorder

final class AudioRecorderTests: XCTestCase {
    func testDefaultMaxDurationIsTenMinutes() async {
        let recorder = AudioRecorder()
        let value = await recorder.maxDuration
        XCTAssertEqual(value, 10 * 60, accuracy: 0.001)
    }

    func testMaxDurationIsInjectable() async {
        let recorder = AudioRecorder(maxDuration: 1.5)
        let value = await recorder.maxDuration
        XCTAssertEqual(value, 1.5, accuracy: 0.001)
    }

    func testMaxDurationHandlerFiresAfterScheduledInterval() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)

        let expectation = expectation(description: "max-duration handler fires")
        let counter = HandlerCallCounter()

        await recorder.setOnMaxDurationReached { [counter, expectation] in
            await counter.increment()
            expectation.fulfill()
        }

        await recorder._armMaxDurationTaskForTesting()

        await fulfillment(of: [expectation], timeout: 1.0)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testCancellingMaxDurationTaskPreventsHandlerCall() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)
        let counter = HandlerCallCounter()

        await recorder.setOnMaxDurationReached { [counter] in
            await counter.increment()
        }

        await recorder._armMaxDurationTaskForTesting()
        await recorder._cancelMaxDurationTaskForTesting()

        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testNoHandlerSetIsSafe() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)
        await recorder._armMaxDurationTaskForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testAudioBufferDetectsDigitalSilence() {
        let silent = AudioBuffer(samples: Data(repeating: 0, count: 8), sampleRate: 16_000, channelCount: 1)
        let nonSilent = AudioBuffer(samples: Data([0, 0, 1, 0]), sampleRate: 16_000, channelCount: 1)
        let empty = AudioBuffer(samples: Data(), sampleRate: 16_000, channelCount: 1)

        XCTAssertTrue(silent.isDigitalSilence)
        XCTAssertFalse(nonSilent.isDigitalSilence)
        XCTAssertFalse(empty.isDigitalSilence)
    }

    func testDiagnosticsExposeNoInFlightConversionBeforeCapture() {
        let recorder = AudioRecorder()
        let snapshot = recorder.diagnosticsSnapshot()

        XCTAssertFalse(snapshot.conversionInFlight)
        XCTAssertNil(snapshot.inFlightTapBufferID)
        XCTAssertNil(snapshot.conversionStartedAt)
    }

    // MARK: - Capture start deadline

    func testStartTimesOutWhenEngineHostNeverCompletes() async {
        let host = StallingEngineHost(hostID: 1)
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 0.2,
            engineHostFactory: { _ in host },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should not succeed while the engine host is stuck")
        } catch AudioRecorderError.engineStartTimedOut(let seconds) {
            XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(host.wasRetired, "a stuck host must be retired so it cannot record later")
        let snapshot = recorder.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.captureStartTimeouts, 1)
        XCTAssertNotNil(snapshot.lastCaptureStartTimeoutAt)
    }

    func testRecorderStaysResponsiveAfterAStuckStart() async throws {
        let stuck = StallingEngineHost(hostID: 1)
        let working = SucceedingEngineHost(hostID: 2)
        let hosts = EngineHostSequence(hosts: [stuck, working])
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 0.2,
            engineHostFactory: { hosts.next(hostID: $0) },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should not succeed while the engine host is stuck")
        } catch AudioRecorderError.engineStartTimedOut {
            // expected
        }

        // The stuck host is still holding its queue. Neither call may wait on it.
        let stopped = await recorder.stop()
        XCTAssertNil(stopped, "no capture was active, so stop() must return nil immediately")

        try await recorder.start()
        let snapshot = recorder.diagnosticsSnapshot()
        XCTAssertTrue(snapshot.isRecording)
        XCTAssertEqual(snapshot.engineHostID, 2)
        XCTAssertTrue(stuck.wasRetired, "the stuck host must have been retired")

        _ = await recorder.stop()
        XCTAssertTrue(working.wasRetired, "stopping must retire the engine host off the actor")
    }

    func testStartPropagatesEngineFailure() async {
        let host = FailingEngineHost(hostID: 1)
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 5,
            engineHostFactory: { _ in host },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should surface the engine failure")
        } catch AudioRecorderError.engineFailedToStart(let message) {
            XCTAssertEqual(message, "converter init failed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.diagnosticsSnapshot().captureStartTimeouts, 0)
    }

    // MARK: - Capture pipeline channel handling

    /// The built-in MacBook mic shows up as a 3-channel discrete array while
    /// another app runs voice processing on it. AVAudioConverter cannot derive
    /// a downmix for that layout and writes zeros (issue #125).
    func testThreeChannelDiscreteInputWithToneOnEveryChannelIsNotSilent() throws {
        let format = try multichannelFormat(channels: 3, tag: kAudioChannelLayoutTag_DiscreteInOrder | 3)
        let result = try runPipeline(inputFormat: format, toneChannels: [0, 1, 2])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
    }

    func testThreeChannelInputKeepsAToneCarriedOnlyByTheLastChannel() throws {
        let format = try multichannelFormat(channels: 3, tag: kAudioChannelLayoutTag_DiscreteInOrder | 3)
        let result = try runPipeline(inputFormat: format, toneChannels: [2])

        XCTAssertFalse(result.isDigitalSilence)
        // Averaged over three channels: 0.5 / 3 of full scale.
        XCTAssertEqual(Double(result.peak), 16_384.0 / 3, accuracy: 1_200)
    }

    func testTwoChannelInputKeepsAToneCarriedOnlyByTheSecondChannel() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let result = try runPipeline(inputFormat: format, toneChannels: [1])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384.0 / 2, accuracy: 1_600)
    }

    func testFourChannelInterleavedInputIsNotSilent() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 4))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: layout
        )
        let result = try runPipeline(inputFormat: format, toneChannels: [0, 1, 2, 3])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
    }

    func testMonoInputConvertsExactlyAsADirectConverterDoes() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let result = try runPipeline(inputFormat: format, toneChannels: [0])

        let input = try toneBuffer(format: format, toneChannels: [0])
        let reference = try directConversion(of: input, to: Self.outputFormat)

        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
        XCTAssertEqual(result.samples, reference)
    }

    func testMultichannelNonFloatInputFailsToStartInsteadOfRecordingSilence() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )

        XCTAssertThrowsError(try CapturePipeline(
            captureID: 1,
            inputFormat: format,
            outputFormat: Self.outputFormat,
            diagnostics: AudioRecorderDiagnosticsState()
        )) { error in
            guard case AudioRecorderError.engineFailedToStart = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: Helpers

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private struct PipelineResult {
        let samples: Data
        let peak: Int

        var isDigitalSilence: Bool {
            AudioBuffer(samples: samples, sampleRate: 16_000, channelCount: 1).isDigitalSilence
        }
    }

    private func multichannelFormat(channels: UInt32, tag: AudioChannelLayoutTag) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        XCTAssertEqual(format.channelCount, channels)
        return format
    }

    /// 0.1 s of a 440 Hz tone at amplitude 0.5 on `toneChannels`, zeros elsewhere.
    private func toneBuffer(format: AVAudioFormat, toneChannels: Set<Int>) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let channels = Int(format.channelCount)
        let stride = buffer.stride
        for frame in 0..<Int(frames) {
            let sample = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
            for channel in 0..<channels {
                let value = toneChannels.contains(channel) ? sample : 0
                if format.isInterleaved {
                    channelData[0][frame * stride + channel] = value
                } else {
                    channelData[channel][frame] = value
                }
            }
        }
        return buffer
    }

    /// Runs one tone buffer through a real `CapturePipeline`, built the way
    /// `CaptureEngineHost` builds it, and returns the captured PCM.
    private func runPipeline(inputFormat: AVAudioFormat, toneChannels: Set<Int>) throws -> PipelineResult {
        let diagnostics = AudioRecorderDiagnosticsState()
        let pipeline = try CapturePipeline(
            captureID: 1,
            inputFormat: inputFormat,
            outputFormat: Self.outputFormat,
            diagnostics: diagnostics
        )
        let input = try toneBuffer(format: inputFormat, toneChannels: toneChannels)
        pipeline.enqueue(
            buffer: input,
            tapBufferID: 1,
            inputFrameLength: input.frameLength,
            enqueuedAtNanos: audioRecorderNowNanos()
        )

        let deadline = Date().addingTimeInterval(2)
        var snapshot = diagnostics.snapshot()
        while (snapshot.appendAttempts < 1 || snapshot.conversionInFlight), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            snapshot = diagnostics.snapshot()
        }
        XCTAssertEqual(snapshot.appendedBuffers, 1, "the buffer must be converted and appended")
        XCTAssertEqual(snapshot.converterFailures, 0)
        XCTAssertEqual(snapshot.outputAllocationFailures, 0)
        XCTAssertEqual(snapshot.emptyOutputBuffers, 0)

        let samples = pipeline.retireAndSnapshot()
        XCTAssertGreaterThan(samples.count, 0)
        return PipelineResult(
            samples: samples,
            peak: peakAmplitude(samples)
        )
    }

    private func directConversion(of input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> Data {
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate + 1024)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity))
        var provided = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        let channel = try XCTUnwrap(output.int16ChannelData?.pointee)
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private func peakAmplitude(_ samples: Data) -> Int {
        samples.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        }
    }
}

// MARK: - Engine host doubles

/// Never calls back — stands in for a CoreAudio call that does not return.
private final class StallingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var retired = false

    init(hostID: UInt64) { self.hostID = hostID }

    var wasRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {}

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}

private final class FailingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64

    init(hostID: UInt64) { self.hostID = hostID }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {
        completion(.failure(.engineFailedToStart("converter init failed")))
    }

    func retire() {}
}

/// Reports a started capture without touching audio hardware.
private final class SucceedingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var retired = false

    init(hostID: UInt64) { self.hostID = hostID }

    var wasRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            ),
            let pipeline = try? CapturePipeline(
                captureID: captureID,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                diagnostics: diagnostics
            )
        else {
            completion(.failure(.engineFailedToStart("test host could not build a pipeline")))
            return
        }
        diagnostics.beginCapture(
            captureID: captureID,
            engineHostID: hostID,
            inputDevice: nil,
            inputFormat: inputFormat
        )
        completion(.success(CaptureStartResult(
            pipeline: pipeline,
            inputDevice: nil,
            inputFormat: inputFormat
        )))
    }

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}

private final class EngineHostSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [CaptureEngineHosting]

    init(hosts: [CaptureEngineHosting]) { self.hosts = hosts }

    func next(hostID: UInt64) -> CaptureEngineHosting {
        lock.lock()
        defer { lock.unlock() }
        return hosts.isEmpty ? StallingEngineHost(hostID: hostID) : hosts.removeFirst()
    }
}


private actor HandlerCallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
