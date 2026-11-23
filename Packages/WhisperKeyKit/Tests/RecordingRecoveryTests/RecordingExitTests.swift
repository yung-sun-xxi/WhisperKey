import AVFoundation
import XCTest
@testable import AudioRecorder
@testable import HistoryStore
@testable import RecordingRecovery

/// Quitting the app, driven end to end: the real recorder on a fake engine, the real
/// history and real files.
@MainActor
final class RecordingExitTests: RecoveryTestCase {

    /// Stands in for `AppCoordinator`: the same calls in the same order, no UI.
    @MainActor
    private final class App {
        let history: HistoryStore
        let keeper: RecordingKeeper
        let host = ToneHost()
        let recorder: AudioRecorder
        let details = RecordingDetails(providerID: "openai", modelID: "gpt-transcribe", language: nil)
        var exit: RecordingExit!

        var microphone = RecordingExit.Microphone.idle
        var recordingID = UUID()
        var events: [String] = []
        var stops = 0
        var replies = 0
        var replyTime: Date?
        var musicPaused = false
        var mayStop = false
        var stop: ((App) async -> Void)?
        var music: ((App) async -> Void)?

        init(history: HistoryStore, folder: RecoveryFolder, bound: TimeInterval) {
            self.history = history
            let host = host
            recorder = AudioRecorder(
                maxDuration: 60,
                startTimeout: 2,
                engineHostFactory: { _ in host },
                permissionCheck: {}
            )
            keeper = RecordingKeeper(history: history, folder: folder)
            exit = RecordingExit(
                keeper: keeper,
                actions: RecordingExit.Actions(
                    microphone: { [unowned self] in self.microphone },
                    cancelStart: { [unowned self] in
                        self.events.append("cancel start")
                        self.keeper.discard(self.recordingID)
                    },
                    stopAndSave: { [unowned self] in
                        self.stops += 1
                        self.events.append("stop")
                        if let stop = self.stop { await stop(self) } else { await self.stopAndSave() }
                    },
                    musicNeedsResuming: { [unowned self] in self.musicPaused },
                    resumeMusic: { [unowned self] in
                        self.events.append("music")
                        if let music = self.music { await music(self) }
                        self.musicPaused = false
                    },
                    reply: { [unowned self] in
                        self.events.append("reply")
                        self.replies += 1
                        self.replyTime = Date()
                    }
                ),
                bound: bound
            )
        }

        func begin() {
            recordingID = UUID()
            microphone = .starting
        }

        func record() async throws {
            begin()
            let sink = keeper.begin(recordingID, sampleRate: 16_000, channelCount: 1, details: details)
            try await recorder.start(sink: sink)
            microphone = .recording
        }

        func stopAndSave() async {
            let outcome = await recorder.stopCapture()
            let saved = try? keeper.finish(outcome, recordingID, details: details)
            events.append(saved == nil ? "nothing to save" : "saved")
        }

        func waitForReply(_ timeout: TimeInterval = 5) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while replies == 0, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        }
    }

    private func makeApp(cap: Int = 30, bound: TimeInterval = 2) -> App {
        App(history: makeHistory(cap: cap), folder: folder, bound: bound)
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - The acceptance cases

    func testTerminatingWhileRecordingSavesOnePendingRowWithTheAudio() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.8)
        XCTAssertEqual(recoveryFiles.count, 1, "the file exists while recording")

        XCTAssertEqual(app.exit.request(), .saveFirst)
        XCTAssertTrue(app.exit.isPending)
        try await app.waitForReply()

        XCTAssertEqual(app.events, ["stop", "saved", "reply"])
        XCTAssertEqual(rowsOnDisk().map(\.id), [app.recordingID])
        let entry = try XCTUnwrap(app.history.entries.first)
        XCTAssertEqual(entry.status, .pendingRecognition)
        XCTAssertTrue(entry.canRetryRecognition)
        XCTAssertGreaterThan(entry.audioDurationSeconds ?? 0, 0)
        let audio = try samples(of: entry, in: app.history)
        XCTAssertTrue(audio.contains { $0 != 0 }, "the tone, not silence")
        XCTAssertEqual(recoveryFiles, [])

        let nextLaunch = makeHistory()
        XCTAssertEqual(folder.recover(into: nextLaunch), RecoveryReport())
        XCTAssertEqual(nextLaunch.entries.map(\.id), [app.recordingID], "one row, not two")
    }

    func testTerminatingWhileIdleExitsAtOnceWithoutARow() async throws {
        let app = makeApp()
        XCTAssertEqual(app.exit.request(), .exitNow)
        try await pause(0.1)
        XCTAssertEqual(app.events, [])
        XCTAssertEqual(rowsOnDisk(), [])
    }

    func testTerminatingWhileStartingCancelsTheStartAndExitsAtOnce() async throws {
        let app = makeApp()
        app.begin()
        _ = app.keeper.begin(app.recordingID, sampleRate: 16_000, channelCount: 1, details: app.details)
        XCTAssertTrue(app.keeper.isWaitingForRow)

        XCTAssertEqual(app.exit.request(), .exitNow)

        XCTAssertEqual(app.events, ["cancel start"])
        XCTAssertEqual(recoveryFiles, [])
        XCTAssertEqual(rowsOnDisk(), [])
    }

    func testARecorderThatNeverStopsDoesNotHoldTheExitPastTheBound() async throws {
        let app = makeApp(bound: 0.6)
        try await app.record()
        try await pause(0.6)
        app.musicPaused = true
        app.stop = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }

        let asked = Date()
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()

        let took = try XCTUnwrap(app.replyTime).timeIntervalSince(asked)
        XCTAssertLessThan(took, 5, "the recorder itself takes a minute")
        XCTAssertEqual(app.events, ["stop", "music", "reply"], "music resumes inside the bound even then")
        XCTAssertEqual(rowsOnDisk(), [])
        XCTAssertEqual(recoveryFiles.count, 1, "the file covers this audio")
    }

    // MARK: - Phases between the recording and its row

    func testAnEscStopInFlightIsWaitedForAndNotRepeated() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.5)
        app.microphone = .idle
        Task {
            try await pause(0.3)
            await app.stopAndSave()
        }
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.stops, 0)
        XCTAssertEqual(app.events, ["saved", "reply"])
        XCTAssertEqual(rowsOnDisk().map(\.id), [app.recordingID])
        XCTAssertEqual(recoveryFiles, [])
    }

    func testOnceTheRowExistsTheExitIsImmediate() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.5)
        app.microphone = .idle
        await app.stopAndSave()
        XCTAssertEqual(app.exit.request(), .exitNow)
        XCTAssertEqual(recoveryFiles, [])
    }

    func testARowThatCannotBeWrittenNeitherBlocksTheExitNorLosesTheAudio() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.6)
        try? FileManager.default.removeItem(at: app.history.audioDirectoryURL)
        try Data().write(to: app.history.audioDirectoryURL)
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.replies, 1)
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    func testAnEarlierRecordingsStopInFlightIsWaitedForWhileTheNextOneStarts() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.5)
        let first = app.recordingID
        app.begin()
        _ = app.keeper.begin(app.recordingID, sampleRate: 16_000, channelCount: 1, details: app.details)
        Task {
            try await pause(0.2)
            let outcome = await app.recorder.stopCapture()
            _ = try app.keeper.finish(outcome, first, details: app.details)
        }
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.events, ["cancel start", "reply"])
        XCTAssertEqual(rowsOnDisk().map(\.id), [first])
        XCTAssertEqual(recoveryFiles, [])
    }

    func testATooShortRecordingLeavesNoRowAndNoFile() async throws {
        let app = makeApp()
        try await app.record()
        app.stop = { app in
            _ = await app.recorder.stopCapture()
            _ = try? app.keeper.finish(.tooShort, app.recordingID, details: app.details)
        }
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.events, ["stop", "reply"])
        XCTAssertEqual(rowsOnDisk(), [])
        XCTAssertEqual(recoveryFiles, [])
    }

    func testHistorySizeZeroExitsWithoutARowOrAFile() async throws {
        let app = makeApp(cap: 0)
        try await app.record()
        try await pause(0.5)
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(rowsOnDisk(), [])
        XCTAssertFalse(exists(folder.directory))
    }

    // MARK: - Once

    func testASecondRequestNeitherStopsNorSavesNorRepliesTwice() async throws {
        let app = makeApp(bound: 20)
        try await app.record()
        try await pause(0.6)
        app.stop = { app in
            while !app.mayStop { try? await Task.sleep(nanoseconds: 5_000_000) }
            await app.stopAndSave()
        }
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await pause(0.05)
        XCTAssertEqual(app.exit.request(), .saveFirst)
        app.microphone = .idle
        XCTAssertEqual(app.exit.request(), .saveFirst, "still saving, whatever the microphone says by now")
        app.mayStop = true
        try await app.waitForReply()
        try await pause(0.3)
        XCTAssertEqual(app.events, ["stop", "saved", "reply"])
        XCTAssertEqual(rowsOnDisk().count, 1)
        XCTAssertFalse(app.exit.isPending)
        XCTAssertEqual(app.exit.request(), .exitNow)
        XCTAssertEqual(app.replies, 1)
    }

    func testAStopThatFinishesAfterTheBoundDoesNotReplyAgain() async throws {
        let app = makeApp(bound: 0.3)
        try await app.record()
        try await pause(0.6)
        app.stop = { app in
            while app.replies == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
            await app.stopAndSave()
        }
        XCTAssertEqual(app.exit.request(), .saveFirst)
        let deadline = Date().addingTimeInterval(10)
        while app.events.count < 3, Date() < deadline { try await pause(0.01) }
        try await pause(0.2)
        XCTAssertEqual(app.events, ["stop", "reply", "saved"])
        XCTAssertEqual(rowsOnDisk().count, 1, "and the row it made is the only one")
    }

    // MARK: - Music

    func testTheAudioIsSavedBeforeTheMusicResumes() async throws {
        let app = makeApp()
        try await app.record()
        try await pause(0.6)
        app.musicPaused = true
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.events, ["stop", "saved", "music", "reply"])
    }

    func testMusicThatNeverAnswersDoesNotHoldTheExitPastTheBound() async throws {
        let app = makeApp(bound: 0.6)
        try await app.record()
        try await pause(0.5)
        app.musicPaused = true
        app.music = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }
        let asked = Date()
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertLessThan(try XCTUnwrap(app.replyTime).timeIntervalSince(asked), 5, "Music itself takes a minute")
        XCTAssertEqual(rowsOnDisk().count, 1)
    }

    /// The recording has its row, but the resume it triggered is still on its way.
    func testAResumeStillOnItsWayIsFinishedBeforeAnIdleExit() async throws {
        let app = makeApp()
        app.musicPaused = true
        XCTAssertEqual(app.exit.request(), .saveFirst)
        try await app.waitForReply()
        XCTAssertEqual(app.events, ["music", "reply"])
    }

    // MARK: - The numbers the install scripts set

    /// `install-app.sh` sends SIGKILL 3 s after SIGTERM, `install-release.sh` 5 s.
    func testTheWholeExitFitsBeforeTheInstallScriptsSIGKILL() {
        XCTAssertEqual(RecordingExit.defaultBound, 2)
        XCTAssertGreaterThan(ExitBackstop.defaultDelay, RecordingExit.defaultBound)
        XCTAssertLessThan(ExitBackstop.defaultDelay, 2.8)
    }

    func testTheBackstopFiresOnceEvenWhileTheMainThreadIsStuck() {
        let fired = Box(0)
        let backstop = ExitBackstop(delay: 1) { fired.update { $0 += 1 } }
        backstop.arm()
        backstop.arm()
        XCTAssertEqual(fired.value, 0, "not before its delay")
        // This test runs on the main thread and never gives it back.
        XCTAssertTrue(waitUntil { fired.value > 0 })
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(fired.value, 1)
    }

    func testABackstopNobodyArmedNeverFires() {
        let fired = Box(0)
        let backstop = ExitBackstop(delay: 0.05) { fired.update { $0 += 1 } }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(fired.value, 0)
        backstop.arm()
        XCTAssertTrue(waitUntil { fired.value == 1 }, "the control")
    }
}

/// An engine that delivers a tone every 20 ms, as a running tap does.
private final class ToneHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64 = 1
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "ToneHost")
    private let running = Box(0)

    func warm() {}

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        onBluetoothInput: @escaping @Sendable (AudioInputDeviceSnapshot) -> Void,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {
        let device = AudioInputDeviceSnapshot(objectID: 1, name: "Fake", uid: "fake")
        do {
            let pipeline = try CapturePipeline(
                captureID: captureID, inputFormat: format, outputFormat: outputFormat, diagnostics: diagnostics
            )
            diagnostics.beginCapture(captureID: captureID, engineHostID: hostID, inputDevice: device, inputFormat: format)
            running.update { $0 += 1 }
            tick(pipeline, generation: running.value)
            completion(.success(CaptureStartResult(pipeline: pipeline, inputDevice: device, inputFormat: format)))
        } catch {
            completion(.failure(.recorder(.engineFailedToStart("\(error)"))))
        }
    }

    private func tick(_ pipeline: CapturePipeline, generation: Int) {
        queue.asyncAfter(deadline: .now() + 0.02) { [self] in
            guard running.value == generation else { return }
            let frames = AVAudioFrameCount(960)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            }
            pipeline.enqueue(
                buffer: buffer, tapBufferID: 1, inputFrameLength: frames,
                enqueuedAtNanos: audioRecorderNowNanos(), sourceID: hostID
            )
            tick(pipeline, generation: generation)
        }
    }

    func continueCapture(
        captureID: UInt64,
        pipeline: CapturePipeline,
        diagnostics: AudioRecorderDiagnosticsState,
        onBluetoothInput: @escaping @Sendable (AudioInputDeviceSnapshot) -> Void,
        completion: @escaping @Sendable (Result<CaptureSwitchResult, CaptureBeginError>) -> Void
    ) {
        completion(.failure(.recorder(.engineFailedToStart("not used here"))))
    }

    func checkRoute(completion: @escaping @Sendable (String?) -> Void) { completion(nil) }
    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
    func endCapture() { running.update { $0 += 1 } }
    func retire() { running.update { $0 += 1 } }
}
