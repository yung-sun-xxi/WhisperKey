import AudioRecorder
import XCTest
@testable import HistoryStore
@testable import RecordingRecovery

/// What a launch makes of the files a dead process left.
final class RecoveryAtLaunchTests: RecoveryTestCase {
    func testALeftoverFileBecomesOnePendingRowAndIsRemoved() throws {
        let header = makeHeader()
        let audio = pcm(2)
        let url = try leaveFile(header, pcm: audio)
        let history = makeHistory()

        let report = folder.recover(into: history)

        XCTAssertEqual(report.recovered, [header.recordingID])
        XCTAssertEqual(history.entries.count, 1)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.id, header.recordingID)
        XCTAssertEqual(entry.createdAt, header.startedAt)
        XCTAssertEqual(entry.status, .pendingRecognition)
        XCTAssertEqual(entry.provider, "groq")
        XCTAssertEqual(entry.model, "whisper-large-v3")
        XCTAssertEqual(entry.language, "ru")
        XCTAssertEqual(entry.audioDurationSeconds ?? 0, 2, accuracy: 0.001)
        XCTAssertFalse(exists(url))

        XCTAssertEqual(folder.recover(into: history), RecoveryReport(), "a second launch finds nothing")
        XCTAssertEqual(rowsOnDisk().count, 1)
    }

    /// Retry reads the row's file, needs a `wav` extension and uploads those bytes.
    func testARecoveredRowCarriesWhatRetryUploads() throws {
        let audio = pcm(2)
        _ = try leaveFile(makeHeader(), pcm: audio)
        let history = makeHistory()
        _ = folder.recover(into: history)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertTrue(entry.canRetryRecognition)
        XCTAssertTrue(history.hasAudio(for: entry))
        XCTAssertEqual((entry.audioFileName as NSString?)?.pathExtension, "wav")
        let wav = try history.audioData(for: entry)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(try samples(of: entry, in: history), audio)

        let recognized = history.markRecognized(
            id: entry.id, text: "hello", providerID: "openai", language: nil, model: "gpt-transcribe",
            estimatedPriceAtTime: nil, currency: nil, destinationUsed: nil, copiedToClipboard: nil, autoPasted: nil
        )
        XCTAssertEqual(recognized?.status, .recognized, "a successful Retry settles the same row")
        XCTAssertEqual(history.entries.count, 1)
    }

    func testAFileCutMidSampleIsRecoveredToItsLastWholeSample() throws {
        let audio = pcm(2)
        _ = try leaveFile(makeHeader(), pcm: audio.dropLast(1_001))
        let history = makeHistory()
        XCTAssertEqual(folder.recover(into: history).recovered.count, 1)
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(try samples(of: entry, in: history), audio.dropLast(1_002))
        XCTAssertEqual(recoveryFiles, [])
    }

    func testAFileWithNoReadableHeaderNoAudioOrTooLittleIsDeletedWithoutARow() throws {
        let torn = try leaveFile(makeHeader(), pcm: Data())
        try Data(RecoveryFileFormat.encode(makeHeader()).prefix(25)).write(to: torn)
        _ = try leaveFile(makeHeader(), pcm: Data())
        _ = try leaveFile(makeHeader(), pcm: pcm(0.29))
        try Data().write(to: folder.url(for: UUID()))
        let kept = makeHeader()
        _ = try leaveFile(kept, pcm: pcm(0.3))
        let history = makeHistory()

        let report = folder.recover(into: history)

        XCTAssertEqual(report.deleted, 4)
        XCTAssertEqual(report.recovered, [kept.recordingID], "exactly AudioRecorder.minDuration is long enough")
        XCTAssertEqual(history.entries.map(\.id), [kept.recordingID])
        XCTAssertEqual(recoveryFiles, [])
    }

    func testHistorySizeZeroDeletesLeftoversAndMakesNoRows() throws {
        _ = try leaveFile(makeHeader(), pcm: pcm(2))
        _ = try leaveFile(makeHeader(), pcm: pcm(2))
        let history = makeHistory(cap: 0)
        let report = folder.recover(into: history)
        XCTAssertEqual(report.deleted, 2)
        XCTAssertEqual(report.recovered, [])
        XCTAssertEqual(recoveryFiles, [])
        XCTAssertEqual(rowsOnDisk().count, 0)
    }

    func testHistorySizeZeroLeavesALiveRecordingsFileAlone() {
        let file = folder.makeFile(makeHeader())
        file.append(pcm(1))
        file.drain()
        let report = folder.recover(into: makeHistory(cap: 0))
        XCTAssertEqual(report.ownedByLiveProcess, 1)
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    func testARecordingStillRunningIsLeftAlone() throws {
        let header = makeHeader()
        let file = folder.makeFile(header)
        file.append(pcm(2))
        file.drain()
        let history = makeHistory()

        XCTAssertEqual(folder.recover(into: history), RecoveryReport(ownedByLiveProcess: 1))
        XCTAssertEqual(history.entries, [])

        file.append(pcm(1))
        file.keep()
        file.drain()
        XCTAssertEqual(folder.recover(into: history).recovered, [header.recordingID], "recoverable once its owner let go")
        XCTAssertEqual(history.entries.first?.audioDurationSeconds ?? 0, 3, accuracy: 0.001)
    }

    func testARowThatCannotBeWrittenLeavesTheFileForTheNextLaunch() throws {
        let header = makeHeader()
        let url = try leaveFile(header, pcm: pcm(2))
        let history = makeHistory()
        // The audio folder's name is taken by a file: the row's audio cannot be written.
        try? FileManager.default.removeItem(at: history.audioDirectoryURL)
        try Data().write(to: history.audioDirectoryURL)

        let report = folder.recover(into: history)
        XCTAssertEqual(report.keptForNextLaunch, 1)
        XCTAssertEqual(report.recovered, [])
        XCTAssertTrue(exists(url))
        XCTAssertFalse(isLocked(url))

        try FileManager.default.removeItem(at: history.audioDirectoryURL)
        XCTAssertEqual(folder.recover(into: history).recovered, [header.recordingID])
        XCTAssertFalse(exists(url))
    }

    /// Part 1 wrote the row and the process died before the file was deleted.
    func testARecordingAlreadyInHistoryIsNotAddedAgain() throws {
        let header = makeHeader()
        _ = try leaveFile(header, pcm: pcm(2))
        let history = makeHistory()
        let first = try XCTUnwrap(history.appendPendingRecognition(
            audioData: Data([1, 2, 3]), fileExtension: "wav", providerID: "openai", language: nil,
            audioDurationSeconds: 2, model: nil, id: header.recordingID
        ))
        _ = history.markRecognized(
            id: first.id, text: "already transcribed", providerID: "openai", language: nil, model: nil,
            estimatedPriceAtTime: nil, currency: nil, destinationUsed: nil, copiedToClipboard: nil, autoPasted: nil
        )

        _ = folder.recover(into: history)
        XCTAssertEqual(rowsOnDisk().map(\.text), ["already transcribed"])
        XCTAssertEqual(recoveryFiles, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.audioDirectoryURL.path), [], "no audio without a row")
    }

    /// The stop had timed out, so history says the capture failed; the audio then turns up.
    func testTheCaptureFailedRowOfTheSameRecordingIsReplaced() throws {
        let header = makeHeader()
        _ = try leaveFile(header, pcm: pcm(2))
        let history = makeHistory()
        history.appendCaptureFailed(providerID: "openai", language: nil, model: nil, message: "other")
        history.appendCaptureFailed(
            providerID: "openai", language: nil, model: nil, message: "timed out",
            id: RecoveryFolder.captureFailureRowID(for: header.recordingID)
        )
        _ = folder.recover(into: history)
        XCTAssertEqual(rowsOnDisk().map(\.status).filter { $0 == .pendingRecognition }.count, 1)
        XCTAssertEqual(rowsOnDisk().filter { $0.status == .captureFailed }.map(\.text), ["other"])
    }

    func testTheCaptureFailedRowIDIsStableAndNotTheRecordingsOwn() {
        let id = UUID()
        XCTAssertEqual(RecoveryFolder.captureFailureRowID(for: id), RecoveryFolder.captureFailureRowID(for: id))
        XCTAssertNotEqual(RecoveryFolder.captureFailureRowID(for: id), id)
        XCTAssertNotEqual(RecoveryFolder.captureFailureRowID(for: id), RecoveryFolder.captureFailureRowID(for: UUID()))
    }

    func testARecoveredRowLandsInDateOrder() throws {
        let history = makeHistory()
        for (text, at) in [("old", 100.0), ("middle", 300), ("new", 500)] {
            _ = history.append(text: text, providerID: "openai", language: nil, now: Date(timeIntervalSince1970: at))
        }
        _ = try leaveFile(makeHeader(startedAt: Date(timeIntervalSince1970: 400)), pcm: pcm(1))
        _ = try leaveFile(makeHeader(startedAt: Date(timeIntervalSince1970: 50)), pcm: pcm(1))
        XCTAssertEqual(folder.recover(into: history).recovered.count, 2)
        XCTAssertEqual(rowsOnDisk().map(\.createdAt.timeIntervalSince1970), [500, 400, 300, 100, 50])
    }

    func testAFullHistoryOfNewerRowsStillShowsTheRecoveredOne() throws {
        let history = makeHistory(cap: 3)
        for index in 1...3 {
            _ = history.append(text: "\(index)", providerID: "openai", language: nil, now: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }
        let header = makeHeader(startedAt: Date(timeIntervalSince1970: 500))
        _ = try leaveFile(header, pcm: pcm(1))
        _ = folder.recover(into: history)
        XCTAssertEqual(history.entries.map(\.text), ["3", "2", ""])
        XCTAssertEqual(history.entries.last?.id, header.recordingID)
        XCTAssertTrue(history.hasAudio(for: try XCTUnwrap(history.entries.last)))
    }

    func testFilesThatAreNotRecoveryFilesAreLeftAlone() throws {
        _ = try leaveFile(makeHeader(), pcm: pcm(1))
        let foreign = folder.directory.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: foreign)
        _ = folder.recover(into: makeHistory())
        XCTAssertEqual(recoveryFiles, ["notes.txt"])
    }

    func testNoFolderMeansNothingToRecover() {
        XCTAssertEqual(folder.recover(into: makeHistory()), RecoveryReport())
        XCTAssertFalse(exists(folder.directory), "and a launch does not create it")
    }

    /// The other app opened the file, waited for its lock and got it only after the first
    /// app had made the row and deleted the file.
    func testAFileDeletedWhileItWasBeingOpenedIsNotRecoveredAgain() throws {
        let header = makeHeader()
        let url = try leaveFile(header, pcm: pcm(1))
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        defer { close(descriptor) }
        let history = makeHistory()
        _ = folder.recover(into: history)
        XCTAssertEqual(history.entries.count, 1)
        _ = history.remove(id: header.recordingID)

        var report = RecoveryReport()
        folder.recoverOpenFile(descriptor: descriptor, at: url, into: history, report: &report)
        XCTAssertEqual(report, RecoveryReport())
        XCTAssertEqual(rowsOnDisk(), [], "the row the user deleted does not come back")
    }
}
