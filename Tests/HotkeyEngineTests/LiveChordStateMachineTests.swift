import XCTest
@testable import HotkeyEngine

/// The Live chord in tap mode: the trigger held plus the chord key opens or closes Live.
/// Everything here is the pure state machine; the event tap is proved separately in
/// `LiveChordTapTests`.
final class LiveChordStateMachineTests: XCTestCase {

    private let live = HotkeyConfig(liveEnabled: true)

    // MARK: - Chord recognition

    func testChordWhileTriggerHeldFromIdleTogglesLive() {
        var sm = HotkeyStateMachine(config: live)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .liveShouldToggle)
    }

    func testTheChordPressDoesNotAlsoStartDictationOnTriggerUp() {
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .liveShouldToggle)

        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    func testASlowChordPastTheTapWindowStillToggles() {
        // The 400 ms tap limit is about dictation; the chord has no time limit.
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 1.5)), .liveShouldToggle)
        XCTAssertNil(sm.process(.triggerUp(at: 2.0)))
    }

    func testChordKeyWithoutTheTriggerDoesNothing() {
        var sm = HotkeyStateMachine(config: live)

        XCTAssertNil(sm.process(.chordKeyDown(at: 0.0)))

        // And the next clean tap still starts dictation.
        _ = sm.process(.triggerDown(at: 1.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 1.1)), .recordingShouldStart)
    }

    func testChordKeyAfterTheTriggerWasReleasedDoesNothing() {
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.triggerUp(at: 0.5))   // too long for a tap: nothing
        XCTAssertNil(sm.process(.chordKeyDown(at: 0.6)))
    }

    // MARK: - Auto-repeat

    func testAutoRepeatAfterTheChordNeverToggles() {
        // Holding the combination for seconds must not flicker Live on and off.
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .liveShouldToggle)
        for i in 1...20 {
            XCTAssertNil(sm.process(.chordKeyRepeat(at: 0.5 + Double(i) * 0.03)))
        }
        XCTAssertNil(sm.process(.triggerUp(at: 2.0)))
    }

    func testAnAutoRepeatAloneNeverToggles() {
        // The chord key was already held when the trigger went down: its repeats are not
        // a chord, and they still count as "another key" so the press is not a clean tap.
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.chordKeyRepeat(at: 0.05)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    // MARK: - Mutual exclusion

    func testTriggerAloneDoesNothingWhileLiveIsActive() {
        var sm = HotkeyStateMachine(config: live)
        sm.setLiveActive(true)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    func testTheChordClosesLiveWhileItIsActive() {
        var sm = HotkeyStateMachine(config: live)
        sm.setLiveActive(true)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .liveShouldToggle)
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    func testTriggerAloneStartsDictationAgainOnceLiveIsOff() {
        var sm = HotkeyStateMachine(config: live)
        sm.setLiveActive(true)
        sm.setLiveActive(false)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 0.1)), .recordingShouldStart)
    }

    func testChordDuringRecordingActsAsThePlainTrigger() {
        var sm = HotkeyStateMachine(config: live, appState: .recording)

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStop)
        XCTAssertNil(sm.process(.chordKeyDown(at: 0.05)))
        XCTAssertNil(sm.process(.chordKeyRepeat(at: 0.6)))
        XCTAssertNil(sm.process(.triggerUp(at: 1.0)))
    }

    func testChordDuringTranscribingYieldsNothing() {
        var sm = HotkeyStateMachine(config: live, appState: .transcribing)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertNil(sm.process(.chordKeyDown(at: 0.05)))
        XCTAssertNil(sm.process(.chordKeyRepeat(at: 0.6)))
        XCTAssertNil(sm.process(.triggerUp(at: 1.0)))
    }

    func testAPressThatBeganInRecordingDoesNotOpenLiveAfterTheAppTurnsIdle() {
        // Trigger-down stops the recording; the transcription is quick and the app is idle
        // again while the trigger is still held. The chord now must not open Live: the
        // press began as "stop dictation".
        var sm = HotkeyStateMachine(config: live, appState: .recording)

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStop)
        sm.setAppState(.transcribing)
        sm.setAppState(.idle)

        XCTAssertNil(sm.process(.chordKeyDown(at: 0.3)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.35)))
    }

    func testAPressThatBeganInTranscribingDoesNotOpenLiveAfterTheAppTurnsIdle() {
        var sm = HotkeyStateMachine(config: live, appState: .transcribing)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        sm.setAppState(.idle)

        XCTAssertNil(sm.process(.chordKeyDown(at: 0.1)))
    }

    func testRecordingStartingBetweenTriggerDownAndChordKeepsLiveClosed() {
        // The menu's Record button, say, starts a recording while the trigger is held.
        var sm = HotkeyStateMachine(config: live)

        _ = sm.process(.triggerDown(at: 0.0))
        sm.setAppState(.recording)

        XCTAssertNil(sm.process(.chordKeyDown(at: 0.05)))
    }

    // MARK: - Escape is not part of Live

    func testEscapeDuringTheChordPressChangesNothingAboutLive() {
        var sm = HotkeyStateMachine(config: live)
        sm.setLiveActive(true)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.escapeDown(at: 0.02)))
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .liveShouldToggle)
    }

    // MARK: - Live disabled or hold mode: exactly today's outputs

    /// One script of input events and the app-state changes between them.
    private enum Step {
        case event(HotkeyStateMachine.Event)
        case appState(HotkeyStateMachine.AppState)
        case liveActive(Bool)
    }

    /// Runs the script twice: once as written against `config`, once against today's
    /// config with every chord event replaced by the `otherKeyDown` that today's runner
    /// produces for the same key (auto-repeats included — they are keyDowns).
    private func assertOutputsMatchToday(
        _ name: String,
        _ script: [Step],
        config: HotkeyConfig,
        initial: HotkeyStateMachine.AppState = .idle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var subject = HotkeyStateMachine(config: config, appState: initial)
        var today = HotkeyStateMachine(
            config: HotkeyConfig(
                trigger: config.trigger,
                mode: config.mode,
                escapeToCancelRecording: config.escapeToCancelRecording
            ),
            appState: initial
        )
        var subjectOutputs: [HotkeyOutput?] = []
        var todayOutputs: [HotkeyOutput?] = []

        for step in script {
            switch step {
            case .event(let event):
                subjectOutputs.append(subject.process(event))
                let todays: HotkeyStateMachine.Event
                switch event {
                case .chordKeyDown(let t), .chordKeyRepeat(let t):
                    todays = .otherKeyDown(at: t)
                default:
                    todays = event
                }
                todayOutputs.append(today.process(todays))
            case .appState(let state):
                subject.setAppState(state)
                today.setAppState(state)
            case .liveActive(let active):
                subject.setLiveActive(active)
            }
        }
        XCTAssertEqual(subjectOutputs, todayOutputs, name, file: file, line: line)
    }

    private var scripts: [(String, HotkeyStateMachine.AppState, [Step])] {
        [
            ("chord from idle", .idle, [
                .event(.triggerDown(at: 0.0)),
                .event(.chordKeyDown(at: 0.05)),
                .event(.chordKeyRepeat(at: 0.06)),
                .event(.triggerUp(at: 0.1)),
            ]),
            ("chord early in a hold", .idle, [
                .event(.triggerDown(at: 0.0)),
                .event(.chordKeyDown(at: 0.03)),
                .event(.triggerUp(at: 0.5)),
            ]),
            ("chord late in a hold", .idle, [
                .event(.triggerDown(at: 0.0)),
                .appState(.recording),
                .event(.chordKeyDown(at: 0.3)),
                .event(.triggerUp(at: 0.5)),
            ]),
            ("trigger alone while told Live is active", .idle, [
                .liveActive(true),
                .event(.triggerDown(at: 0.0)),
                .event(.triggerUp(at: 0.1)),
            ]),
            ("chord while recording", .recording, [
                .event(.triggerDown(at: 0.0)),
                .event(.chordKeyDown(at: 0.05)),
                .event(.triggerUp(at: 0.1)),
            ]),
        ]
    }

    func testLiveDisabledTapModeOutputsAreExactlyToday() {
        let config = HotkeyConfig(mode: .tap, liveEnabled: false)
        for (name, initial, script) in scripts {
            assertOutputsMatchToday(name, script, config: config, initial: initial)
        }
    }

    func testHoldModeWithLiveEnabledOutputsAreExactlyToday() {
        // Hold-mode Live is a later ticket; until then the chord key is an ordinary key.
        let config = HotkeyConfig(mode: .hold, liveEnabled: true)
        for (name, initial, script) in scripts {
            assertOutputsMatchToday(name, script, config: config, initial: initial)
        }
    }

    func testLiveDisabledChordIsAnOrdinaryKeyThatSpoilsTheTap() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(liveEnabled: false))

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.chordKeyDown(at: 0.05)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    func testLiveDisabledIgnoresLiveActive() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(liveEnabled: false))
        sm.setLiveActive(true)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 0.1)), .recordingShouldStart)
    }

    func testHoldModeChordInsideTheAbortWindowStopsAsToday() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold, liveEnabled: true))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        XCTAssertEqual(sm.process(.chordKeyDown(at: 0.05)), .recordingShouldStop)
    }

    // MARK: - Config defaults keep every call site as it was

    func testLiveIsOffByDefaultWithSlashAsTheChordKey() {
        let config = HotkeyConfig()
        XCTAssertFalse(config.liveEnabled)
        XCTAssertEqual(config.liveChordKeyCode, 44)   // kVK_ANSI_Slash
    }
}
