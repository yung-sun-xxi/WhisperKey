import XCTest
@testable import Live

final class LivePCMTests: XCTestCase {

    func testFormatIsMonoPCM16At24kHz() {
        XCTAssertEqual(LivePCM.sampleRate, 24_000)
        XCTAssertEqual(LivePCM.channelCount, 1)
        XCTAssertEqual(LivePCM.bytesPerSample, 2)
        XCTAssertEqual(LivePCM.bytesPerSecond, 48_000)
    }

    func testDurationOfByteCount() {
        XCTAssertEqual(LivePCM.duration(ofByteCount: 48_000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(LivePCM.duration(ofByteCount: 4_800), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LivePCM.duration(ofByteCount: 0), 0, accuracy: 1e-9)
    }

    func testByteCountForDurationIsWholeSamples() {
        XCTAssertEqual(LivePCM.byteCount(for: 0.5), 24_000)
        XCTAssertEqual(LivePCM.byteCount(for: 0.01), 480)
        // 1.5 samples' worth of time rounds down to one whole sample: never half a sample.
        XCTAssertEqual(LivePCM.byteCount(for: 1.5 / 24_000), 2)
        XCTAssertEqual(LivePCM.byteCount(for: -1), 0)
    }

    func testMillisecondsOfByteCount() {
        XCTAssertEqual(LivePCM.milliseconds(ofByteCount: 48_000), 1_000)
        // 4801 bytes is 2400 whole samples plus a stray byte: 100 ms.
        XCTAssertEqual(LivePCM.milliseconds(ofByteCount: 4_801), 100)
        XCTAssertEqual(LivePCM.milliseconds(ofByteCount: 47), 0)
    }

    func testBase64ChunkEncoding() {
        XCTAssertEqual(LivePCM.base64(Data([0x01, 0x02, 0xFF])), "AQL/")
        XCTAssertEqual(LivePCM.base64(Data()), "")
    }
}
