import XCTest
@testable import HotkeyEngine

final class HotkeyEngineStateMachineTests: XCTestCase {

    // MARK: - Clean tap starts a recording

    func testCleanTapStartsRecording() {
        var sm = HotkeyStateMachine()

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        let output = sm.process(.triggerUp(at: 0.1))

        XCTAssertEqual(output, .recordingShouldStart)
    }

    // MARK: - Modifier-as-modifier (e.g. ⌥e) does NOT start

    func testTapWithOtherKeyDoesNotStart() {
        var sm = HotkeyStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.otherKeyDown(at: 0.05))
        let output = sm.process(.triggerUp(at: 0.1))

        XCTAssertNil(output)
        XCTAssertEqual(sm.appState, .idle)
    }

    // MARK: - Hold longer than 400 ms is not a tap

    func testTapLongerThan400msDoesNotStart() {
        var sm = HotkeyStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        let output = sm.process(.triggerUp(at: 0.5))

        XCTAssertNil(output)
        XCTAssertEqual(sm.appState, .idle)
    }

    // MARK: - 400 ms boundary is inclusive

    func testTapAtExactly400msStarts() {
        var sm = HotkeyStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        let output = sm.process(.triggerUp(at: 0.4))

        XCTAssertEqual(output, .recordingShouldStart)
    }

    // MARK: - Stop is unconditional in tap mode

    func testTapDuringRecordingAlwaysStops() {
        var sm = HotkeyStateMachine(appState: .recording)

        let output = sm.process(.triggerDown(at: 10.0))

        XCTAssertEqual(output, .recordingShouldStop)
    }

    func testStopFiresEvenAfterOtherKey() {
        // While recording, ⌘C with the right hand (if trigger is right cmd) stops recording.
        // PRD documents this trade-off explicitly.
        var sm = HotkeyStateMachine(appState: .recording)

        _ = sm.process(.otherKeyDown(at: 1.0))
        let output = sm.process(.triggerDown(at: 1.05))

        XCTAssertEqual(output, .recordingShouldStop)
    }

    // MARK: - Escape cancels active recording

    func testEscapeDuringRecordingCancelsInTapMode() {
        var sm = HotkeyStateMachine(appState: .recording)

        let output = sm.process(.escapeDown(at: 10.0))

        XCTAssertEqual(output, .recordingShouldCancel)
    }

    func testEscapeDuringRecordingDoesNotCancelWhenDisabledInTapMode() {
        var sm = HotkeyStateMachine(
            config: HotkeyConfig(escapeToCancelRecording: false),
            appState: .recording
        )

        let output = sm.process(.escapeDown(at: 10.0))

        XCTAssertNil(output)
    }

    func testEscapeWhileIdleDoesNotStartRecording() {
        var sm = HotkeyStateMachine()

        XCTAssertNil(sm.process(.escapeDown(at: 0.0)))
        XCTAssertEqual(sm.appState, .idle)
    }

    func testEscapeDuringPendingTapPreventsStart() {
        var sm = HotkeyStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.escapeDown(at: 0.05))

        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    // MARK: - Trigger events ignored while transcribing

    func testTriggerIgnoredWhileTranscribing() {
        var sm = HotkeyStateMachine(appState: .transcribing)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
    }

    func testSuppressionCounterIncrementsOnTriggerWhileTranscribing() {
        var sm = HotkeyStateMachine(appState: .transcribing)
        XCTAssertEqual(sm.transcribingSuppressionCount, 0)
        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.transcribingSuppressionCount, 1)
        _ = sm.process(.triggerUp(at: 0.1))
        XCTAssertEqual(sm.transcribingSuppressionCount, 2)
        _ = sm.process(.otherKeyDown(at: 0.2))
        XCTAssertEqual(sm.transcribingSuppressionCount, 2,
                       "non-trigger keys are not counted as suppressed")
        _ = sm.process(.escapeDown(at: 0.3))
        XCTAssertEqual(sm.transcribingSuppressionCount, 2,
                       "Escape is not counted as a suppressed trigger")
    }

    func testSuppressionCounterDoesNotIncrementWhenIdle() {
        var sm = HotkeyStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.triggerUp(at: 0.1))
        XCTAssertEqual(sm.transcribingSuppressionCount, 0)
    }

    func testSuppressionCounterIncrementsInHoldModeToo() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold), appState: .transcribing)
        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.transcribingSuppressionCount, 1)
    }

    func testNextHotkeyAfterTranscriptionResolvesBehavesNormally() {
        var sm = HotkeyStateMachine(appState: .transcribing)
        _ = sm.process(.triggerDown(at: 0.0))
        sm.setAppState(.idle)
        _ = sm.process(.triggerDown(at: 1.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 1.05)), .recordingShouldStart)
    }

    // MARK: - Stale press state is reset on app state change

    func testHoldStateResetsWhenAppStateChanges() {
        var sm = HotkeyStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        sm.setAppState(.recording)
        sm.setAppState(.idle)

        // After app state churn, a stray triggerUp should not retroactively start a recording.
        XCTAssertNil(sm.process(.triggerUp(at: 0.05)))
    }

    func testTriggerUpWithoutPriorDownIsIgnored() {
        var sm = HotkeyStateMachine()
        XCTAssertNil(sm.process(.triggerUp(at: 0.0)))
    }

    // MARK: - Two-tap workflow round-trip

    func testTwoTapWorkflow() {
        var sm = HotkeyStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 0.1)), .recordingShouldStart)

        sm.setAppState(.recording)
        XCTAssertEqual(sm.process(.triggerDown(at: 1.0)), .recordingShouldStop)

        sm.setAppState(.transcribing)
        XCTAssertNil(sm.process(.triggerDown(at: 1.5)))

        sm.setAppState(.idle)
        _ = sm.process(.triggerDown(at: 2.0))
        XCTAssertEqual(sm.process(.triggerUp(at: 2.05)), .recordingShouldStart)
    }

    // MARK: - Hold mode

    func testHoldModeStartsImmediatelyOnTriggerDown() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        let output = sm.process(.triggerDown(at: 0.0))

        XCTAssertEqual(output, .recordingShouldStart)
    }

    func testHoldModeStopsOnTriggerUpAfterAppStateChangesToRecording() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        sm.setAppState(.recording)

        XCTAssertEqual(sm.process(.triggerUp(at: 0.5)), .recordingShouldStop)
    }

    func testHoldModeStopsOnTriggerUpEvenBeforeAppStateCatchesUp() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)

        XCTAssertEqual(sm.process(.triggerUp(at: 0.05)), .recordingShouldStop)
    }

    func testHoldModeOtherKeyWithinAbortWindowStopsRecording() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        sm.setAppState(.recording)

        XCTAssertEqual(sm.process(.otherKeyDown(at: 0.05)), .recordingShouldStop)
    }

    func testHoldModeOtherKeyWithinAbortWindowStopsBeforeAppStateCatchesUp() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)

        XCTAssertEqual(sm.process(.otherKeyDown(at: 0.05)), .recordingShouldStop)
    }

    func testHoldModeEscapeCancelsBeforeAppStateCatchesUp() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)

        XCTAssertEqual(sm.process(.escapeDown(at: 0.05)), .recordingShouldCancel)
    }

    func testHoldModeEscapeCancelsWhileRecording() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        sm.setAppState(.recording)

        XCTAssertEqual(sm.process(.escapeDown(at: 0.5)), .recordingShouldCancel)
    }

    func testHoldModeEscapeDoesNotCancelWhenDisabled() {
        var sm = HotkeyStateMachine(
            config: HotkeyConfig(mode: .hold, escapeToCancelRecording: false)
        )

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        sm.setAppState(.recording)

        XCTAssertNil(sm.process(.escapeDown(at: 0.5)))
    }

    func testHoldModeOtherKeyAfterAbortWindowDoesNotStopRecording() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold))

        XCTAssertEqual(sm.process(.triggerDown(at: 0.0)), .recordingShouldStart)
        sm.setAppState(.recording)

        XCTAssertNil(sm.process(.otherKeyDown(at: 0.081)))
    }

    func testHoldModeIgnoresTriggerDownWhileRecording() {
        var sm = HotkeyStateMachine(config: HotkeyConfig(mode: .hold), appState: .recording)

        XCTAssertNil(sm.process(.triggerDown(at: 1.0)))
    }
}
