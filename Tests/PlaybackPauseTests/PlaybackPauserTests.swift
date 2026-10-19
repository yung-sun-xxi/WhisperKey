import XCTest
@testable import PlaybackPause

/// Rules 1, 3 and 4 of #196, driven through the two calls AppCoordinator makes.
@MainActor
final class PlaybackPauserTests: XCTestCase {
    private let ownPID: pid_t = 4242
    private var music: FakeMusic!
    private var probe: FakeProbe!
    private var keys: FakeKeyPoster!
    private var pauser: PlaybackPauser!

    private func make(musicPlaying: Bool = false, processes: [AudioProcess] = []) {
        music = FakeMusic(playing: musicPlaying)
        probe = FakeProbe(processes)
        keys = FakeKeyPoster()
        pauser = PlaybackPauser(music: music, probe: probe, keyPoster: keys, ownPID: ownPID)
    }

    private func start(enabled: Bool = true) async {
        pauser.recordingDidStart(enabled: enabled)
        await pauser.waitForPendingWork()
    }

    private func end() async {
        pauser.recordingDidEnd()
        await pauser.waitForPendingWork()
    }

    // MARK: - Toggle and nothing to pause

    func testToggleOffProbesNothingAndPostsNoKey() async {
        make(musicPlaying: true, processes: [.chrome()])

        await start(enabled: false)
        await end()

        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(music.pauseCalls, 0)
        XCTAssertEqual(music.resumeCalls, 0)
        XCTAssertEqual(keys.posts, 0)
    }

    func testNothingEligibleOutputtingPostsNoKey() async {
        make(processes: [
            AudioProcess(bundleID: "yung-sun-xxi.WhisperKey.dev", pid: ownPID, isRunningOutput: true),
            AudioProcess(bundleID: nil, pid: 300, isRunningOutput: true),
            .systemSounds(),
            AudioProcess(bundleID: "com.microsoft.teams2.helper", pid: 310, isRunningOutput: true),
            .appleMusic(running: true),
            .chrome(running: false),
        ])

        await start()
        await end()

        XCTAssertEqual(keys.posts, 0)
    }

    // MARK: - Rule 1 and 4: Apple Music through AppleScript only

    func testMusicPlayingIsPausedThroughAppleScriptAndNoKeyIsPosted() async {
        make(musicPlaying: true, processes: [.appleMusic(), .chrome()])

        await start()
        XCTAssertEqual(music.pauseCalls, 1)
        XCTAssertFalse(music.playing)
        XCTAssertEqual(keys.posts, 0)

        await end()
        XCTAssertEqual(music.resumeCalls, 1)
        XCTAssertEqual(keys.posts, 0)
    }

    func testMusicPausedByHandStartsNothingEvenWithItsOutputFlagUp() async {
        make(musicPlaying: false, processes: [.appleMusic(running: true)])

        await start()
        await end()

        XCTAssertEqual(keys.posts, 0)
        XCTAssertEqual(music.resumeCalls, 0)
    }

    // MARK: - Rule 2 and 3: everything else through the media key

    func testEligibleProcessGetsOneKeyAtStartAndOneAtEnd() async {
        make(processes: [.chrome(), .systemSounds(running: false)])

        await start()
        XCTAssertEqual(keys.posts, 1)

        // The paused helper keeps its process object but stops output after a while.
        probe.processes = [.chrome(running: false), .systemSounds(running: false)]
        await end()
        XCTAssertEqual(keys.posts, 2)
        XCTAssertEqual(music.resumeCalls, 0)
    }

    func testEndKeyStillPostedWhileThePausedProcessKeepsItsOutputFlagUp() async {
        make(processes: [.chrome()])

        await start()
        await end()

        XCTAssertEqual(keys.posts, 2)
    }

    func testIneligibleSoundAtTheEndDoesNotBlockTheResume() async {
        make(processes: [.chrome()])

        await start()
        probe.processes = [.chrome(running: false), .systemSounds(running: true), .appleMusic(running: true)]
        await end()

        XCTAssertEqual(keys.posts, 2)
    }

    func testEndKeySkippedWhenThePausedProcessIsGone() async {
        make(processes: [.chrome()])

        await start()
        XCTAssertEqual(keys.posts, 1)

        probe.processes = [.systemSounds(running: false)]
        await end()
        XCTAssertEqual(keys.posts, 1)
    }

    func testEndKeySkippedWhenAnotherEligibleProcessIsOutputting() async {
        make(processes: [.chrome()])

        await start()
        XCTAssertEqual(keys.posts, 1)

        probe.processes = [.chrome(running: false), .vlc(running: true)]
        await end()
        XCTAssertEqual(keys.posts, 1)
    }

    func testAnotherPlayerSittingSilentDoesNotBlockTheResume() async {
        make(processes: [.chrome(), .vlc(running: false)])

        await start()
        await end()

        XCTAssertEqual(keys.posts, 2)
    }

    func testRecordingThatPausedNothingResumesNothing() async {
        make(processes: [])

        await start()
        // Something starts playing during the recording.
        probe.processes = [.chrome()]
        await end()

        XCTAssertEqual(keys.posts, 0)
        XCTAssertEqual(music.resumeCalls, 0)
    }

    // MARK: - Overlapping recordings resume once

    func testOverlappingRecordingsWithTheKeyPauseOnceAndResumeOnce() async {
        make(processes: [.chrome()])

        await start()
        // The paused helper still reports output when the second recording starts.
        await start()
        XCTAssertEqual(keys.posts, 1)

        await end()
        await end()
        XCTAssertEqual(keys.posts, 2)
    }

    func testRecordingEndedBeforeItsPauseLandedResumesOnceAfterTheNextOne() async {
        make(processes: [.chrome()])

        // Neither pause attempt has run yet when the first recording ends.
        pauser.recordingDidStart(enabled: true)
        pauser.recordingDidEnd()
        pauser.recordingDidStart(enabled: true)
        await pauser.waitForPendingWork()
        XCTAssertEqual(keys.posts, 1)

        await end()
        XCTAssertEqual(keys.posts, 2)
        await end()
        XCTAssertEqual(keys.posts, 2)
    }

    func testOverlappingRecordingsWithMusicResumeOnce() async {
        make(musicPlaying: true)

        pauser.recordingDidStart(enabled: true)
        pauser.recordingDidEnd()
        pauser.recordingDidStart(enabled: true)
        await pauser.waitForPendingWork()

        await end()
        await end()
        XCTAssertEqual(music.resumeCalls, 1)
        XCTAssertEqual(keys.posts, 0)
    }

    func testRecordingStartedWhileTheResumeIsInFlightKeepsThePause() async {
        make(processes: [.chrome()])

        await start()
        XCTAssertEqual(keys.posts, 1)

        // The next recording starts before the end probe has answered.
        pauser.recordingDidEnd()
        pauser.recordingDidStart(enabled: true)
        await pauser.waitForPendingWork()
        XCTAssertEqual(keys.posts, 1)

        await end()
        XCTAssertEqual(keys.posts, 2)
    }
}
