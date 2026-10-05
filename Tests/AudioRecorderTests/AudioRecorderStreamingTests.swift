import AVFoundation
import XCTest
@testable import AudioRecorder

/// The stream path of `AudioRecorder`, driven through a fake engine host that
/// feeds synthetic microphone buffers into the real `CapturePipeline` and its
/// real `AVAudioConverter`. What is not covered here: a live `AVAudioEngine`
/// tap on real hardware, which is not reachable from a unit test.
final class AudioRecorderStreamingTests: XCTestCase {
    // MARK: - PCM16 arithmetic

    func testStreamFormatIsPCM16At24kHzMono() {
        XCTAssertEqual(AudioRecorder.streamFormat, PCM16Format(sampleRate: 24_000, channelCount: 1))
        XCTAssertEqual(AudioRecorder.streamFormat.bytesPerFrame, 2)
        XCTAssertEqual(AudioRecorder.streamFormat.bytesPerSecond, 48_000, accuracy: 0.001)
    }

    func testPCM16FormatConvertsBetweenBytesAndDuration() {
        let stream = PCM16Format(sampleRate: 24_000, channelCount: 1)
        XCTAssertEqual(stream.duration(byteCount: 4_800), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(stream.duration(byteCount: 0), 0, accuracy: 0.000_001)
        XCTAssertEqual(stream.byteCount(duration: 0.1), 4_800)
        XCTAssertEqual(stream.byteCount(duration: 0), 0)
        XCTAssertEqual(stream.byteCount(duration: -1), 0)

        let dictation = PCM16Format(sampleRate: 16_000, channelCount: 1)
        XCTAssertEqual(dictation.byteCount(duration: 1), 32_000)

        let stereo = PCM16Format(sampleRate: 24_000, channelCount: 2)
        XCTAssertEqual(stereo.bytesPerFrame, 4)
        XCTAssertEqual(stereo.duration(byteCount: 9_600), 0.1, accuracy: 0.000_001)
    }

    func testPCM16ByteCountNeverSplitsAFrame() {
        let stream = PCM16Format(sampleRate: 24_000, channelCount: 1)
        // 1 ms at 24 kHz is 24 frames; 1/48000 s is half a frame and rounds to a whole one.
        XCTAssertEqual(stream.byteCount(duration: 0.001), 48)
        XCTAssertEqual(stream.byteCount(duration: 1.0 / 48_000) % stream.bytesPerFrame, 0)
    }

    // MARK: - Stream delivery

    func testStreamDeliversConvertedChunksInOrderAt24kHz() async throws {
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host)
        let sink = ChunkCollector()

        try await recorder.startStreaming(onChunk: sink.append)

        let format = try XCTUnwrap(host.outputFormat)
        XCTAssertEqual(format.sampleRate, 24_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(format.isInterleaved)

        // Three 100 ms microphone buffers at 48 kHz, each a different level,
        // fed one at a time so the append gate never drops one.
        let levels: [Float] = [0.1, 0.3, 0.5]
        for (index, level) in levels.enumerated() {
            host.feed(frames: 4_800, level: level)
            try await sink.waitForCount(index + 1)
        }

        let chunks = sink.chunks
        XCTAssertEqual(chunks.count, 3)
        let medians = chunks.map(medianSample)
        for (median, level) in zip(medians, levels) {
            XCTAssertEqual(Double(median), Double(level) * 32_767, accuracy: 400)
        }

        // 300 ms of input becomes 300 ms of 24 kHz PCM16, less what the
        // resampler is still holding: it emits in bursts and catches up later
        // (measured here: 2040, 2048, 2048 frames for 2400 each, so 44 ms held).
        let total = chunks.reduce(0) { $0 + $1.count }
        assertConvertedBytes(total, of: 0.3, in: AudioRecorder.streamFormat)
        XCTAssertTrue(chunks.allSatisfy { $0.count % 2 == 0 }, "every chunk holds whole Int16 frames")

        await recorder.stopStreaming()
    }

    func testStopStreamingStopsDeliveryAndRetiresTheHost() async throws {
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host)
        let sink = ChunkCollector()

        try await recorder.startStreaming(onChunk: sink.append)
        host.feed(frames: 4_800, level: 0.2)
        try await sink.waitForCount(1)

        await recorder.stopStreaming()
        XCTAssertTrue(host.wasRetired, "stopping a stream must retire its engine host")

        host.feed(frames: 4_800, level: 0.2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sink.chunks.count, 1, "no chunk may arrive for audio fed after the stream stopped")
    }

    func testStreamAccumulatesNothing() async throws {
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host)
        let sink = ChunkCollector()

        try await recorder.startStreaming(onChunk: sink.append)
        host.feed(frames: 4_800, level: 0.2)
        try await sink.waitForCount(1)

        let pipeline = try XCTUnwrap(host.pipeline)
        await recorder.stopStreaming()
        XCTAssertEqual(pipeline.retireAndSnapshot(), Data(), "a stream hands chunks out and keeps none")
    }

    func testAudioConvertedBeforeTheSinkAttachesIsFlushedFirstAndInOrder() async throws {
        // The engine starts before the recorder can attach the sink; whatever
        // was converted in that window must lead the stream, not be lost or trail.
        let host = FeedableEngineHost(hostID: 1)
        let diagnostics = AudioRecorderDiagnosticsState()
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
        ))
        host.begin(
            captureID: 1,
            outputFormat: outputFormat,
            diagnostics: diagnostics,
            previousInputDevice: nil,
            completion: { _ in }
        )
        let pipeline = try XCTUnwrap(host.pipeline)

        host.feed(frames: 4_800, level: 0.1)
        for _ in 0..<200 where diagnostics.snapshot().appendedBuffers < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(diagnostics.snapshot().appendedBuffers, 1)

        let sink = ChunkCollector()
        pipeline.attachChunkSink(sink.append)
        try await sink.waitForCount(1)
        host.feed(frames: 4_800, level: 0.4)
        try await sink.waitForCount(2)

        let medians = sink.chunks.map(medianSample)
        guard medians.count == 2 else {
            XCTFail("expected the flushed chunk and the live one, got \(medians.count)")
            return
        }
        XCTAssertEqual(Double(medians[0]), 0.1 * 32_767, accuracy: 400)
        XCTAssertEqual(Double(medians[1]), 0.4 * 32_767, accuracy: 400)
        XCTAssertEqual(pipeline.streamedBytes, sink.chunks.reduce(0) { $0 + $1.count })
        XCTAssertEqual(pipeline.retireAndSnapshot(), Data())
    }

    func testStreamHasNoMaxDurationCallback() async throws {
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host, maxDuration: 0.05)
        let counter = StreamHandlerCounter()
        await recorder.setOnMaxDurationReached { [counter] in counter.increment() }

        try await recorder.startStreaming(onChunk: { _ in })
        XCTAssertNotNil(host.outputFormat, "the stream must actually have started")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 0, "a Live session closes itself; the recorder must not cut a stream")
        await recorder.stopStreaming()
    }

    func testDictationStillFiresMaxDurationThroughTheSameSeam() async throws {
        // Control for the test above: the same seam does observe the timer for dictation.
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host, maxDuration: 0.05)
        let counter = StreamHandlerCounter()
        await recorder.setOnMaxDurationReached { [counter] in counter.increment() }

        try await recorder.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 1)
        _ = await recorder.stop()
    }

    // MARK: - Mutual exclusion

    func testStartWhileStreamingThrowsAlreadyRecording() async throws {
        let hosts = FeedableHostFactory()
        let recorder = makeRecorder(factory: hosts)

        try await recorder.startStreaming(onChunk: { _ in })
        do {
            try await recorder.start()
            XCTFail("start() must not open a second capture while a stream runs")
        } catch AudioRecorderError.alreadyRecording {
            // expected
        }
        XCTAssertEqual(hosts.created, 1, "the refused start must not build an engine host")

        let stopped = await recorder.stop()
        XCTAssertNil(stopped, "stop() is the dictation stop and has nothing to return during a stream")
        XCTAssertFalse(hosts.host(at: 0).wasRetired, "stop() must not end a running stream")

        await recorder.stopStreaming()
        try await recorder.start()
        XCTAssertEqual(hosts.created, 2, "after the stream stops, dictation starts normally")
        _ = await recorder.stop()
    }

    func testStreamWhileRecordingThrowsAlreadyRecording() async throws {
        let hosts = FeedableHostFactory()
        let recorder = makeRecorder(factory: hosts)

        try await recorder.start()
        do {
            try await recorder.startStreaming(onChunk: { _ in })
            XCTFail("startStreaming must not open a second capture while dictation records")
        } catch AudioRecorderError.alreadyRecording {
            // expected
        }
        XCTAssertEqual(hosts.created, 1, "the refused stream must not build an engine host")

        await recorder.stopStreaming()
        XCTAssertFalse(hosts.host(at: 0).wasRetired, "stopStreaming() must not end a running dictation")

        _ = await recorder.stop()
        try await recorder.startStreaming(onChunk: { _ in })
        XCTAssertEqual(hosts.created, 2, "after dictation stops, a stream starts normally")
        await recorder.stopStreaming()
    }

    func testStreamWhileStreamingThrowsAlreadyRecording() async throws {
        let hosts = FeedableHostFactory()
        let recorder = makeRecorder(factory: hosts)

        try await recorder.startStreaming(onChunk: { _ in })
        do {
            try await recorder.startStreaming(onChunk: { _ in })
            XCTFail("a second stream must be refused")
        } catch AudioRecorderError.alreadyRecording {
            // expected
        }
        XCTAssertEqual(hosts.created, 1)
        await recorder.stopStreaming()
    }

    func testStreamRefusedWhileADictationStartIsInFlight() async throws {
        let gate = HeldEngineHost(hostID: 1)
        let hosts = FeedableHostFactory(first: gate)
        let recorder = makeRecorder(factory: hosts, startTimeout: 5)

        let dictation = Task { try await recorder.start() }
        try await gate.waitUntilBegun()
        do {
            try await recorder.startStreaming(onChunk: { _ in })
            XCTFail("a stream must not start while a dictation start is still waiting on its engine")
        } catch AudioRecorderError.alreadyRecording {
            // expected
        }
        gate.release()
        try await dictation.value
        XCTAssertEqual(hosts.created, 1)
        _ = await recorder.stop()
    }

    func testDictationRefusedWhileAStreamStartIsInFlight() async throws {
        let gate = HeldEngineHost(hostID: 1)
        let hosts = FeedableHostFactory(first: gate)
        let recorder = makeRecorder(factory: hosts, startTimeout: 5)

        let stream = Task { try await recorder.startStreaming(onChunk: { _ in }) }
        try await gate.waitUntilBegun()
        do {
            try await recorder.start()
            XCTFail("dictation must not start while a stream start is still waiting on its engine")
        } catch AudioRecorderError.alreadyRecording {
            // expected
        }
        gate.release()
        try await stream.value
        XCTAssertEqual(hosts.created, 1)
        await recorder.stopStreaming()
        XCTAssertTrue(gate.wasRetired)
    }

    func testStreamSurfacesStartTimeoutAndPermissionDenial() async throws {
        let stalled = makeRecorder(factory: FeedableHostFactory(first: HeldEngineHost(hostID: 1)), startTimeout: 0.2)
        do {
            try await stalled.startStreaming(onChunk: { _ in })
            XCTFail("a stuck engine must time out")
        } catch AudioRecorderError.engineStartTimedOut(let seconds) {
            XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
        }
        XCTAssertEqual(stalled.diagnosticsSnapshot().captureStartTimeouts, 1)

        let denied = AudioRecorder(
            maxDuration: 60,
            startTimeout: 5,
            engineHostFactory: { FeedableEngineHost(hostID: $0) },
            permissionCheck: { throw AudioRecorderError.microphonePermissionDenied }
        )
        do {
            try await denied.startStreaming(onChunk: { _ in })
            XCTFail("a denied microphone must refuse the stream")
        } catch AudioRecorderError.microphonePermissionDenied {
            // expected
        }
    }

    // MARK: - Dictation is unchanged

    func testDictationStillReturnsA16kHzBuffer() async throws {
        let host = FeedableEngineHost(hostID: 1)
        let recorder = makeRecorder(host: host)

        try await recorder.start()
        let format = try XCTUnwrap(host.outputFormat)
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)

        host.feed(frames: 4_800, level: 0.25)
        try await waitForAppendedBuffers(recorder, count: 1)
        // Past the 300 ms minimum, so the capture is kept.
        try await Task.sleep(nanoseconds: 350_000_000)

        let stopped = await recorder.stop()
        let buffer = try XCTUnwrap(stopped)
        XCTAssertEqual(buffer.sampleRate, 16_000)
        XCTAssertEqual(buffer.channelCount, 1)
        assertConvertedBytes(buffer.samples.count, of: 0.1, in: PCM16Format(sampleRate: 16_000, channelCount: 1))
        XCTAssertEqual(Double(medianSample(buffer.samples)), 0.25 * 32_767, accuracy: 400)
    }

    // MARK: - Helpers

    private func makeRecorder(
        host: FeedableEngineHost,
        maxDuration: TimeInterval = 60
    ) -> AudioRecorder {
        AudioRecorder(
            maxDuration: maxDuration,
            startTimeout: 5,
            engineHostFactory: { _ in host },
            permissionCheck: {}
        )
    }

    private func makeRecorder(
        factory: FeedableHostFactory,
        startTimeout: TimeInterval = 5
    ) -> AudioRecorder {
        AudioRecorder(
            maxDuration: 60,
            startTimeout: startTimeout,
            engineHostFactory: { factory.make(hostID: $0) },
            permissionCheck: {}
        )
    }

    /// `byteCount` is `duration` of audio in `format`, short by at most the
    /// resampler's lag (60 ms allowed; up to 44 ms measured) and never longer
    /// than the input. A wrong output rate misses this by a third or more.
    private func assertConvertedBytes(
        _ byteCount: Int,
        of duration: TimeInterval,
        in format: PCM16Format,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = format.byteCount(duration: duration)
        let allowedLag = format.byteCount(duration: 0.06)
        XCTAssertLessThanOrEqual(byteCount, expected, "more audio out than went in", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            byteCount,
            expected - allowedLag,
            "\(byteCount) bytes is short of \(expected) by more than the resampler's lag",
            file: file,
            line: line
        )
    }

    private func waitForAppendedBuffers(_ recorder: AudioRecorder, count: UInt64) async throws {
        for _ in 0..<200 {
            if recorder.diagnosticsSnapshot().appendedBuffers >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the pipeline never converted \(count) buffer(s)")
    }
}

private func medianSample(_ data: Data) -> Int16 {
    let samples: [Int16] = data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Int16.self))
    }
    guard !samples.isEmpty else { return 0 }
    return samples.sorted()[samples.count / 2]
}

// MARK: - Doubles

/// Builds the real `CapturePipeline` with a real converter from a 48 kHz
/// Float32 "microphone", and lets a test push buffers into it as the input tap would.
private final class FeedableEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var retired = false
    private var storedPipeline: CapturePipeline?
    private var storedOutputFormat: AVAudioFormat?
    private var tapSequence: UInt64 = 0
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    init(hostID: UInt64) { self.hostID = hostID }

    var wasRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    var pipeline: CapturePipeline? {
        lock.lock()
        defer { lock.unlock() }
        return storedPipeline
    }

    var outputFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutputFormat
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
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
        lock.lock()
        storedPipeline = pipeline
        storedOutputFormat = outputFormat
        lock.unlock()
        completion(.success(CaptureStartResult(pipeline: pipeline, inputDevice: nil, inputFormat: inputFormat)))
    }

    /// A constant-level buffer, as the input tap would hand it over.
    func feed(frames: AVAudioFrameCount, level: Float) {
        guard let pipeline,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else {
            XCTFail("feed called before begin, or buffer allocation failed")
            return
        }
        buffer.frameLength = frames
        for index in 0..<Int(frames) { channel[index] = level }
        lock.lock()
        tapSequence += 1
        let tapID = tapSequence
        lock.unlock()
        pipeline.enqueue(
            buffer: buffer,
            inputFormat: inputFormat,
            tapBufferID: tapID,
            inputFrameLength: frames,
            enqueuedAtNanos: audioRecorderNowNanos()
        )
    }

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}

/// Holds `begin` until the test releases it, then succeeds like a real host.
private final class HeldEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var pending: (() -> Void)?
    private var begun = false
    private let inner: FeedableEngineHost

    init(hostID: UInt64) {
        self.hostID = hostID
        inner = FeedableEngineHost(hostID: hostID)
    }

    var wasRetired: Bool { inner.wasRetired }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, AudioRecorderError>) -> Void
    ) {
        lock.lock()
        begun = true
        pending = { [inner] in
            inner.begin(
                captureID: captureID,
                outputFormat: outputFormat,
                diagnostics: diagnostics,
                previousInputDevice: previousInputDevice,
                completion: completion
            )
        }
        lock.unlock()
    }

    private var hasBegun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return begun
    }

    func waitUntilBegun() async throws {
        for _ in 0..<200 {
            if hasBegun { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("begin was never called")
    }

    func release() {
        lock.lock()
        let work = pending
        pending = nil
        lock.unlock()
        work?()
    }

    func retire() { inner.retire() }
}

private final class FeedableHostFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var first: CaptureEngineHosting?
    private var hosts: [CaptureEngineHosting] = []

    init(first: CaptureEngineHosting? = nil) { self.first = first }

    func make(hostID: UInt64) -> CaptureEngineHosting {
        lock.lock()
        defer { lock.unlock() }
        let host: CaptureEngineHosting
        if let first {
            host = first
            self.first = nil
        } else {
            host = FeedableEngineHost(hostID: hostID)
        }
        hosts.append(host)
        return host
    }

    var created: Int {
        lock.lock()
        defer { lock.unlock() }
        return hosts.count
    }

    func host(at index: Int) -> FeedableEngineHost {
        lock.lock()
        defer { lock.unlock() }
        return hosts[index] as! FeedableEngineHost
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []

    var append: @Sendable (Data) -> Void {
        { [self] chunk in
            lock.lock()
            stored.append(chunk)
            lock.unlock()
        }
    }

    var chunks: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func waitForCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if chunks.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("expected \(count) chunk(s), got \(chunks.count)")
    }
}

private final class StreamHandlerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
