import AudioRecorder
import XCTest
@testable import RecordingRecovery

final class RecoveryFileFormatTests: RecoveryTestCase {
    func testHeaderAndAudioRoundTrip() throws {
        let header = makeHeader()
        let audio = pcm(0.5)
        let read = try XCTUnwrap(RecoveryFileFormat.decode(RecoveryFileFormat.encode(header) + audio))
        XCTAssertEqual(read.header, header)
        XCTAssertEqual(read.audio, AudioBuffer(samples: audio, sampleRate: 16_000, channelCount: 1))
    }

    func testOptionalFieldsMayBeMissing() throws {
        var header = makeHeader()
        header.modelID = nil
        header.language = nil
        let read = try XCTUnwrap(RecoveryFileFormat.decode(RecoveryFileFormat.encode(header) + pcm(0.1)))
        XCTAssertEqual(read.header, header)
    }

    func testATornLastSampleIsDropped() throws {
        let audio = pcm(0.5)
        let read = try XCTUnwrap(RecoveryFileFormat.decode(RecoveryFileFormat.encode(makeHeader()) + audio.dropLast(1)))
        XCTAssertEqual(read.audio.samples, audio.dropLast(2), "half a sample is not a sample")
    }

    func testATornLastFrameOfTwoChannelsIsDropped() throws {
        var header = makeHeader()
        header.channelCount = 2
        let audio = pcm(0.5)
        let read = try XCTUnwrap(RecoveryFileFormat.decode(RecoveryFileFormat.encode(header) + audio.dropLast(1)))
        XCTAssertEqual(read.audio.samples, audio.dropLast(4))
    }

    func testAFileCutAnywhereInsideItsHeaderIsUnreadable() {
        let bytes = RecoveryFileFormat.encode(makeHeader())
        XCTAssertGreaterThan(bytes.count, 20)
        for count in 0..<bytes.count {
            XCTAssertNil(RecoveryFileFormat.decode(bytes.prefix(count)), "\(count) bytes")
        }
    }

    func testForeignBytesAreUnreadable() {
        XCTAssertNotNil(RecoveryFileFormat.decode(RecoveryFileFormat.encode(makeHeader())), "the control")
        XCTAssertNil(RecoveryFileFormat.decode(Data(repeating: 0xFF, count: 4_096)))
        XCTAssertNil(RecoveryFileFormat.decode(pcm(1)))
        var otherVersion = RecoveryFileFormat.encode(makeHeader())
        otherVersion[8] = 2
        XCTAssertNil(RecoveryFileFormat.decode(otherVersion))
    }

    /// The encoder turns the rate into an integer, which traps on these values.
    func testAnImpossibleFormatIsUnreadable() {
        for (rate, channels) in [(-1, 1), (0, 1), (1e12, 1), (16_000, 0), (16_000, 1_000)] as [(Double, UInt32)] {
            var header = makeHeader()
            header.sampleRate = rate
            header.channelCount = channels
            XCTAssertNil(RecoveryFileFormat.decode(RecoveryFileFormat.encode(header) + pcm(0.5)), "\(rate) Hz, \(channels) ch")
        }
        XCTAssertNotNil(RecoveryFileFormat.decode(RecoveryFileFormat.encode(makeHeader()) + pcm(0.5)), "the control")
    }
}
