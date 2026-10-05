import AVFoundation
import XCTest
@testable import AudioRecorder

/// Drives the real `CapturePipeline` and the real `AVAudioConverter` with
/// about 40 s of microphone-shaped buffers, one at a time as the input tap
/// hands them over, and checks how much audio comes out the other side.
/// No fake: only the `AVAudioEngine` tap itself is replaced by a loop.
final class CapturePipelineThroughputTests: XCTestCase {
    private static let seconds: Double = 40
    private static let minimumShare = 0.97

    // MARK: - Stream, 24 kHz

    func testStreamKeepsUpWith48kHzIn4096FrameBuffers() throws {
        try assertStreamThroughput(inputRate: 48_000, framesPerBuffer: 4_096)
    }

    func testStreamKeepsUpWith48kHzIn4800FrameBuffers() throws {
        try assertStreamThroughput(inputRate: 48_000, framesPerBuffer: 4_800)
    }

    func testStreamKeepsUpWith48kHzIn512FrameBuffers() throws {
        try assertStreamThroughput(inputRate: 48_000, framesPerBuffer: 512)
    }

    func testStreamKeepsUpWith44_1kHzIn4096FrameBuffers() throws {
        try assertStreamThroughput(inputRate: 44_100, framesPerBuffer: 4_096)
    }

    func testStreamKeepsUpWith44_1kHzIn4410FrameBuffers() throws {
        try assertStreamThroughput(inputRate: 44_100, framesPerBuffer: 4_410)
    }

    // MARK: - Dictation, 16 kHz

    func testDictationKeepsUpWith48kHzIn4800FrameBuffers() throws {
        try assertDictationThroughput(inputRate: 48_000, framesPerBuffer: 4_800)
    }

    func testDictationKeepsUpWith44_1kHzIn4096FrameBuffers() throws {
        try assertDictationThroughput(inputRate: 44_100, framesPerBuffer: 4_096)
    }

    // MARK: - Harness

    private func assertStreamThroughput(
        inputRate: Double,
        framesPerBuffer: AVAudioFrameCount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let format = AudioRecorder.streamFormat
        let run = try drive(inputRate: inputRate, outputRate: format.sampleRate, framesPerBuffer: framesPerBuffer, stream: true)
        report("stream", inputRate: inputRate, framesPerBuffer: framesPerBuffer, run: run, format: format, file: file, line: line)
    }

    private func assertDictationThroughput(
        inputRate: Double,
        framesPerBuffer: AVAudioFrameCount,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let format = PCM16Format(sampleRate: 16_000, channelCount: 1)
        let run = try drive(inputRate: inputRate, outputRate: format.sampleRate, framesPerBuffer: framesPerBuffer, stream: false)
        report("dictation", inputRate: inputRate, framesPerBuffer: framesPerBuffer, run: run, format: format, file: file, line: line)
    }

    private struct Run {
        let inputFrames: Int
        let outputBytes: Int
        let chunkCount: Int
        let harnessRetries: UInt64
        let diagnostics: AudioRecorderDiagnosticsSnapshot
    }

    private func report(
        _ label: String,
        inputRate: Double,
        framesPerBuffer: AVAudioFrameCount,
        run: Run,
        format: PCM16Format,
        file: StaticString,
        line: UInt
    ) {
        let inputSeconds = Double(run.inputFrames) / inputRate
        let expected = format.byteCount(duration: inputSeconds)
        let share = Double(run.outputBytes) / Double(expected)
        let dropped = run.diagnostics.appendTasksDropped - run.harnessRetries
        let message = String(
            format: "%@ %.0f Hz x %d frames: %d of %d bytes = %.1f%%, appendTasksDropped=%llu, emptyOutputBuffers=%llu, appendedBuffers=%llu",
            label, inputRate, Int(framesPerBuffer), run.outputBytes, expected, share * 100,
            dropped, run.diagnostics.emptyOutputBuffers, run.diagnostics.appendedBuffers
        )
        print("THROUGHPUT " + message)
        XCTAssertEqual(dropped, 0, "sequential feeding must never hit the append gate: " + message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(share, Self.minimumShare, message, file: file, line: line)
        XCTAssertLessThanOrEqual(run.outputBytes, expected + format.bytesPerFrame * 2, "more audio out than went in: " + message, file: file, line: line)
    }

    private func drive(
        inputRate: Double,
        outputRate: Double,
        framesPerBuffer: AVAudioFrameCount,
        stream: Bool
    ) throws -> Run {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let diagnostics = AudioRecorderDiagnosticsState()
        diagnostics.beginCapture(captureID: 1, engineHostID: 1, inputDevice: nil, inputFormat: inputFormat)
        let pipeline = CapturePipeline(
            captureID: 1,
            converter: converter,
            outputFormat: outputFormat,
            diagnostics: diagnostics
        )

        let sink = ByteCounter()
        if stream {
            pipeline.attachChunkSink(sink.add)
        }

        let bufferCount = Int((Self.seconds * inputRate / Double(framesPerBuffer)).rounded(.up))
        var phase = 0.0
        var harnessRetries: UInt64 = 0
        let step = 2 * Double.pi * 440 / inputRate
        for index in 0..<bufferCount {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerBuffer))
            buffer.frameLength = framesPerBuffer
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(framesPerBuffer) {
                channel[frame] = Float(0.3 * sin(phase))
                phase += step
            }
            // The gate is released a moment after the diagnostics say the
            // previous conversion finished; a buffer refused in that moment is
            // offered again, as the next tap buffer would be, and not counted.
            while true {
                let droppedBefore = diagnostics.snapshot().appendTasksDropped
                pipeline.enqueue(
                    buffer: buffer,
                    inputFormat: inputFormat,
                    tapBufferID: UInt64(index + 1),
                    inputFrameLength: framesPerBuffer,
                    enqueuedAtNanos: audioRecorderNowNanos()
                )
                if diagnostics.snapshot().appendTasksDropped == droppedBefore { break }
                harnessRetries += 1
                usleep(100)
            }
            try waitForCompletedAppends(diagnostics, count: UInt64(index + 1))
        }

        let snapshot = diagnostics.snapshot()
        let accumulated = pipeline.retireAndSnapshot()
        return Run(
            inputFrames: bufferCount * Int(framesPerBuffer),
            outputBytes: stream ? sink.total : accumulated.count,
            chunkCount: sink.count,
            harnessRetries: harnessRetries,
            diagnostics: snapshot
        )
    }

    /// The tap's next buffer arrives only after this one is converted, so the
    /// append gate is never involved: what goes missing, the converter lost.
    private func waitForCompletedAppends(_ diagnostics: AudioRecorderDiagnosticsState, count: UInt64) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let snapshot = diagnostics.snapshot()
            let completed = snapshot.appendedBuffers + snapshot.emptyOutputBuffers
                + snapshot.converterFailures + snapshot.outputAllocationFailures + snapshot.appendIgnored
            if completed >= count && !snapshot.conversionInFlight { return }
            usleep(200)
        }
        XCTFail("conversion \(count) never completed")
        throw CancellationError()
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var chunks = 0

    var add: @Sendable (Data) -> Void {
        { [self] chunk in
            lock.lock()
            bytes += chunk.count
            chunks += 1
            lock.unlock()
        }
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}
