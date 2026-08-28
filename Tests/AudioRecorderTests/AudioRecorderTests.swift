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
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            completion(.failure(.engineFailedToStart("test host could not build a converter")))
            return
        }
        diagnostics.beginCapture(
            captureID: captureID,
            engineHostID: hostID,
            inputDevice: nil,
            inputFormat: inputFormat
        )
        let pipeline = CapturePipeline(
            captureID: captureID,
            converter: converter,
            outputFormat: outputFormat,
            diagnostics: diagnostics
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
