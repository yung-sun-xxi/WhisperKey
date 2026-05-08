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

    // MARK: - Trigger events ignored while transcribing

    func testTriggerIgnoredWhileTranscribing() {
        var sm = HotkeyStateMachine(appState: .transcribing)

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
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
}
