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
}

private actor HandlerCallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
