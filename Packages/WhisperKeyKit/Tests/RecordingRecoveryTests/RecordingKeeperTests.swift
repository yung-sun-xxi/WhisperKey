import AudioEncoder
import AudioRecorder
import XCTest
@testable import HistoryStore
@testable import RecordingRecovery

/// The life of one recording's file, from the start of the recording to its history row.
@MainActor
final class RecordingKeeperTests: RecoveryTestCase {
    private let details = RecordingDetails(providerID: "openai", modelID: "gpt-transcribe", language: "es")

    private func buffer(_ seconds: Double = 1, seed: Int = 0) -> AudioBuffer {
        AudioBuffer(samples: pcm(seconds, seed: seed), sampleRate: 16_000, channelCount: 1)
    }

    /// Starts a recording and captures `buffer` through the sink, as the recorder would.
    private func begin(_ keeper: RecordingKeeper, _ id: UUID, _ buffer: AudioBuffer) throws {
        let sink = try XCTUnwrap(keeper.begin(id, sampleRate: 16_000, channelCount: 1, details: details))
        sink(buffer.samples)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: folder.url(for: id)).count ?? 0) ?? 0 > buffer.samples.count })
    }

    private func blockRows(of history: HistoryStore) throws {
        try? FileManager.default.removeItem(at: history.audioDirectoryURL)
        try Data().write(to: history.audioDirectoryURL)
    }

    func testWhileRecordingTheFileHoldsTheAudioAndWhereItCameFrom() throws {
        let id = UUID()
        let keeper = RecordingKeeper(history: makeHistory(), folder: folder)
        try begin(keeper, id, buffer())
        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: id))))
        XCTAssertEqual(read.header.recordingID, id)
        XCTAssertEqual(read.header.startedAt.timeIntervalSinceNow, 0, accuracy: 10)
        XCTAssertEqual(read.header.providerID, "openai")
        XCTAssertEqual(read.header.modelID, "gpt-transcribe")
        XCTAssertEqual(read.header.language, "es")
        XCTAssertEqual(read.audio, buffer())
    }

    func testANormalStopMakesTheRowAndLeavesNoFile() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        let encoded = try AudioEncoder().encode(buffer())
        let entry = try XCTUnwrap(keeper.save(encoded, duration: 1, id, details: details))
        XCTAssertEqual(entry.id, id, "the recording's id is the row's id")
        XCTAssertEqual(entry.status, .pendingRecognition)
        XCTAssertEqual(recoveryFiles, [], "gone by the time save returns")
        XCTAssertEqual(history.entries.map(\.id), [id])
        XCTAssertEqual(try history.audioData(for: entry), encoded.data)
    }

    func testEscMakesTheRowAndLeavesNoFile() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        let entry = try XCTUnwrap(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.provider, "openai")
        XCTAssertEqual(entry.model, "gpt-transcribe")
        XCTAssertEqual(entry.language, "es")
        XCTAssertEqual(try samples(of: entry, in: history), buffer().samples)
        XCTAssertEqual(recoveryFiles, [])
    }

    func testATooShortOrSilentlyFailedRecordingLeavesNoFileAndNoRow() throws {
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        for outcome in [AudioRecorderStopOutcome.tooShort, .noAudio] {
            let id = UUID()
            try begin(keeper, id, buffer(0.1))
            XCTAssertNil(try keeper.finish(outcome, id, details: details))
            XCTAssertEqual(recoveryFiles, [], "\(outcome)")
        }
        XCTAssertEqual(history.entries, [])
        XCTAssertFalse(keeper.isWaitingForRow)
    }

    /// Two stops ran and the other one got the audio: whichever comes first, one row.
    func testAStopThatFoundNothingRecordingLeavesTheAudioToTheOtherStop() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        XCTAssertNil(try keeper.finish(.notRecording, id, details: details))
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertNotNil(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertNil(try keeper.finish(.notRecording, id, details: details))
        XCTAssertEqual(history.entries.map(\.id), [id])
        XCTAssertTrue(waitUntil { recoveryFiles.isEmpty })
    }

    func testACancelledStartLeavesNoFile() throws {
        let id = UUID()
        let keeper = RecordingKeeper(history: makeHistory(), folder: folder)
        _ = keeper.begin(id, sampleRate: 16_000, channelCount: 1, details: details)
        keeper.discard(id)
        XCTAssertFalse(keeper.isWaitingForRow)
        let control = UUID()
        try begin(keeper, control, buffer())
        XCTAssertEqual(recoveryFiles, [folder.url(for: control).lastPathComponent])
    }

    func testHistorySizeZeroAtTheStartWritesNoFileAndNoRow() throws {
        let id = UUID()
        let history = makeHistory(cap: 0)
        let keeper = RecordingKeeper(history: history, folder: folder)
        XCTAssertNil(keeper.begin(id, sampleRate: 16_000, channelCount: 1, details: details))
        XCTAssertFalse(exists(folder.directory))
        XCTAssertNil(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertEqual(rowsOnDisk(), [])
        XCTAssertFalse(keeper.isWaitingForRow)
    }

    func testHistorySizeSetToZeroDuringARecordingDropsItsFile() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        keeper.historySizeChanged(to: 10)
        XCTAssertEqual(recoveryFiles.count, 1, "any other size keeps it")
        history.setMaxEntries(0)
        keeper.historySizeChanged(to: 0)
        XCTAssertEqual(recoveryFiles, [])
        XCTAssertNil(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertEqual(recoveryFiles, [])
    }

    func testARowThatCannotBeWrittenKeepsTheFileUntilTheTextIsDelivered() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        try blockRows(of: history)
        XCTAssertNil(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertFalse(keeper.isWaitingForRow, "an exit must not wait for a row that cannot be written")
        XCTAssertTrue(waitUntil { !isLocked(folder.url(for: id)) }, "the next launch may recover it")

        keeper.textDelivered(id)
        XCTAssertEqual(recoveryFiles, [])
    }

    func testAKeptFileIsRecoveredOnceTheRowCanBeWritten() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        try blockRows(of: history)
        _ = try keeper.finish(.recorded(buffer()), id, details: details)
        XCTAssertTrue(waitUntil { !isLocked(folder.url(for: id)) })
        try FileManager.default.removeItem(at: history.audioDirectoryURL)

        let nextLaunch = makeHistory()
        XCTAssertEqual(folder.recover(into: nextLaunch).recovered, [id])
        XCTAssertEqual(try samples(of: try XCTUnwrap(nextLaunch.entries.first), in: nextLaunch), buffer().samples)
    }

    func testAHistorySetToZeroDropsAKeptFileToo() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        try blockRows(of: history)
        _ = try keeper.finish(.recorded(buffer()), id, details: details)
        XCTAssertTrue(waitUntil { !isLocked(folder.url(for: id)) })
        keeper.historySizeChanged(to: 0)
        XCTAssertEqual(recoveryFiles, [])
    }

    func testAStopThatTimedOutKeepsTheFileUntilItsBufferArrives() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        keeper.stopTimedOut(id)
        XCTAssertFalse(keeper.isWaitingForRow, "the exit has nothing to wait for; the file covers it")
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertTrue(isLocked(folder.url(for: id)), "still this process's recording")

        XCTAssertNotNil(try keeper.finish(.recorded(buffer()), id, details: details))
        XCTAssertEqual(recoveryFiles, [])
        XCTAssertEqual(history.entries.map(\.id), [id])
    }

    /// A timed-out stop can outlive the start of the next recording.
    func testTwoOverlappingRecordingsNeverTouchEachOthersFile() throws {
        let (first, second) = (UUID(), UUID())
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        let firstSink = try XCTUnwrap(keeper.begin(first, sampleRate: 16_000, channelCount: 1, details: details))
        firstSink(buffer(1, seed: 1).samples)
        keeper.stopTimedOut(first)
        try begin(keeper, second, buffer(1, seed: 2))
        firstSink(buffer(0.5, seed: 3).samples)
        XCTAssertTrue(waitUntil { (try? Data(contentsOf: folder.url(for: first)).count) ?? 0 > 48_000 })

        _ = try keeper.finish(.recorded(buffer(1, seed: 1)), first, details: details)
        XCTAssertEqual(recoveryFiles, [folder.url(for: second).lastPathComponent])
        firstSink(buffer(0.5, seed: 4).samples)
        let read = try XCTUnwrap(RecoveryFileFormat.decode(Data(contentsOf: folder.url(for: second))))
        XCTAssertEqual(read.audio, buffer(1, seed: 2), "a late chunk of the first recording never reaches the second's file")
        XCTAssertTrue(keeper.isWaitingForRow, "the second recording still has no row")
        _ = try keeper.finish(.recorded(buffer(1, seed: 2)), second, details: details)
        XCTAssertFalse(keeper.isWaitingForRow)
        XCTAssertEqual(Set(history.entries.map(\.id)), [first, second])
        XCTAssertEqual(recoveryFiles, [])
    }

    func testSavingTheSameRecordingTwiceMakesOneRow() throws {
        let id = UUID()
        let history = makeHistory()
        let keeper = RecordingKeeper(history: history, folder: folder)
        try begin(keeper, id, buffer())
        _ = try keeper.save(buffer(), id, details: details)
        _ = try keeper.save(buffer(), id, details: details)
        XCTAssertEqual(history.entries.map(\.id), [id])
    }

    func testWaitingEndsWhenTheLastRecordingHasItsRow() async throws {
        let (first, second) = (UUID(), UUID())
        let keeper = RecordingKeeper(history: makeHistory(), folder: folder)
        _ = keeper.begin(first, sampleRate: 16_000, channelCount: 1, details: details)
        _ = keeper.begin(second, sampleRate: 16_000, channelCount: 1, details: details)
        let done = Box(false)
        let waiting = Task { await keeper.waitForRows(); done.value = true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(done.value)
        keeper.discard(first)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(done.value)
        _ = try keeper.finish(.recorded(buffer()), second, details: details)
        await waiting.value
        XCTAssertTrue(done.value)
        await keeper.waitForRows()
    }
}
