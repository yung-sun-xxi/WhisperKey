import XCTest
@testable import HotkeyEngine

final class HoldToRevealStateMachineTests: XCTestCase {

    // MARK: - Reveal after the threshold

    func testHoldPastThresholdReveals() {
        var sm = HoldToRevealStateMachine()

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        let output = sm.process(.holdThresholdElapsed(at: 0.5))

        XCTAssertEqual(output, .reveal)
        XCTAssertTrue(sm.isRevealed)
    }

    func testThresholdSignalBeforeThresholdElapsedDoesNotReveal() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        let output = sm.process(.holdThresholdElapsed(at: 0.49))

        XCTAssertNil(output)
        XCTAssertFalse(sm.isRevealed)
    }

    func testThresholdSignalWithoutAHeldTriggerRevealsNothing() {
        var sm = HoldToRevealStateMachine()

        let output = sm.process(.holdThresholdElapsed(at: 5.0))

        XCTAssertNil(output)
        XCTAssertFalse(sm.isRevealed)
    }

    func testCustomThresholdIsHonoured() {
        var sm = HoldToRevealStateMachine(holdThreshold: 1.0)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.6)))
        XCTAssertEqual(sm.process(.holdThresholdElapsed(at: 1.0)), .reveal)
    }

    // MARK: - A short tap produces nothing at all

    func testShortTapProducesNoOutput() {
        var sm = HoldToRevealStateMachine()

        XCTAssertNil(sm.process(.triggerDown(at: 0.0)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.12)))
        XCTAssertFalse(sm.isRevealed)
    }

    func testTapThenSecondTapStillProducesNothing() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.triggerUp(at: 0.1)))
        _ = sm.process(.triggerDown(at: 0.2))
        XCTAssertNil(sm.process(.triggerUp(at: 0.3)))
    }

    // MARK: - Release after the reveal commits

    func testReleaseAfterRevealCommits() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        let output = sm.process(.triggerUp(at: 0.9))

        XCTAssertEqual(output, .commit)
        XCTAssertFalse(sm.isRevealed)
    }

    // MARK: - Another key during the hold cancels

    func testOtherKeyBeforeRevealCancelsThePendingReveal() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.otherKeyDown(at: 0.1)))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))
        XCTAssertFalse(sm.isRevealed)
        XCTAssertNil(sm.process(.triggerUp(at: 0.7)))
    }

    func testOtherKeyAfterRevealDismisses() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        let output = sm.process(.otherKeyDown(at: 0.6))

        XCTAssertEqual(output, .dismiss)
        XCTAssertFalse(sm.isRevealed)
    }

    func testReleaseAfterDismissalDoesNotCommit() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        XCTAssertEqual(sm.process(.otherKeyDown(at: 0.6)), .dismiss)

        XCTAssertNil(sm.process(.triggerUp(at: 0.8)))
    }

    func testASecondOtherKeyAfterDismissalIsSilent() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        _ = sm.process(.otherKeyDown(at: 0.6))

        XCTAssertNil(sm.process(.otherKeyDown(at: 0.7)))
    }

    // MARK: - Releasing a foreign modifier is not "another key"

    func testForeignModifierReleaseDoesNotCancelPendingReveal() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.otherModifierUp(at: 0.1)))

        XCTAssertEqual(sm.process(.holdThresholdElapsed(at: 0.5)), .reveal)
    }

    func testForeignModifierReleaseDoesNotDismissAnOpenPanel() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))

        XCTAssertNil(sm.process(.otherModifierUp(at: 0.6)))
        XCTAssertTrue(sm.isRevealed)
        XCTAssertEqual(sm.process(.triggerUp(at: 0.7)), .commit)
    }

    // MARK: - Never reveals while recording or transcribing

    func testDoesNotRevealWhileRecording() {
        var sm = HoldToRevealStateMachine(appState: .recording)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))
        XCTAssertFalse(sm.isRevealed)
    }

    func testDoesNotRevealWhileTranscribing() {
        var sm = HoldToRevealStateMachine(appState: .transcribing)

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))
        XCTAssertFalse(sm.isRevealed)
    }

    func testRecordingStartingMidHoldPreventsTheReveal() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.setAppState(.recording))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))
    }

    func testRecordingStartingWhileRevealedDismissesThePanel() {
        var sm = HoldToRevealStateMachine()

        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))

        XCTAssertEqual(sm.setAppState(.recording), .dismiss)
        XCTAssertFalse(sm.isRevealed)
    }

    func testReturningToIdleAllowsRevealingAgain() {
        var sm = HoldToRevealStateMachine(appState: .transcribing)
        _ = sm.process(.triggerDown(at: 0.0))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))

        _ = sm.setAppState(.idle)
        _ = sm.process(.triggerDown(at: 1.0))
        XCTAssertEqual(sm.process(.holdThresholdElapsed(at: 1.5)), .reveal)
    }

    // MARK: - Arrow keys steer the selection instead of abandoning the gesture

    func testArrowKeyWhileRevealedMovesTheSelectionAndLeavesThePanelUp() {
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))

        XCTAssertEqual(
            sm.process(.arrowKeyDown(direction: .down, at: 0.6)),
            .moveSelection(.down)
        )
        XCTAssertTrue(sm.isRevealed)

        XCTAssertEqual(
            sm.process(.arrowKeyDown(direction: .up, at: 0.7)),
            .moveSelection(.up)
        )
        XCTAssertTrue(sm.isRevealed)
    }

    func testReleaseAfterAnArrowStillCommits() {
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        _ = sm.process(.arrowKeyDown(direction: .down, at: 0.6))

        XCTAssertEqual(sm.process(.triggerUp(at: 0.8)), .commit)
        XCTAssertFalse(sm.isRevealed)
    }

    func testHeldArrowRepeatsKeepTheGestureAlive() {
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))

        for step in 1...20 {
            XCTAssertEqual(
                sm.process(.arrowKeyDown(direction: .down, at: 0.5 + Double(step) * 0.03)),
                .moveSelection(.down)
            )
        }
        XCTAssertTrue(sm.isRevealed)
    }

    func testArrowKeyBeforeTheThresholdCancelsTheGestureLikeAnyOtherKey() {
        // The panel is not up yet, so the arrow belongs to whatever the user is typing in.
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))

        XCTAssertNil(sm.process(.arrowKeyDown(direction: .down, at: 0.2)))
        XCTAssertNil(sm.process(.holdThresholdElapsed(at: 0.5)))
        XCTAssertFalse(sm.isRevealed)
    }

    func testArrowKeyWithNothingInFlightProducesNothing() {
        var sm = HoldToRevealStateMachine()

        XCTAssertNil(sm.process(.arrowKeyDown(direction: .up, at: 1.0)))
        XCTAssertFalse(sm.isRevealed)
    }

    func testArrowKeyAfterADismissalProducesNothing() {
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        XCTAssertEqual(sm.process(.otherKeyDown(at: 0.6)), .dismiss)

        XCTAssertNil(sm.process(.arrowKeyDown(direction: .down, at: 0.7)))
        XCTAssertNil(sm.process(.triggerUp(at: 0.8)))
    }

    func testRecordingStartingWhileRevealedStopsArrowsFromMovingAnything() {
        var sm = HoldToRevealStateMachine()
        _ = sm.process(.triggerDown(at: 0.0))
        _ = sm.process(.holdThresholdElapsed(at: 0.5))
        XCTAssertEqual(sm.setAppState(.recording), .dismiss)

        XCTAssertNil(sm.process(.arrowKeyDown(direction: .down, at: 0.6)))
    }

    // MARK: - The default threshold is the documented 500 ms

    func testDefaultHoldThresholdIs500ms() {
        XCTAssertEqual(HoldToRevealStateMachine.defaultHoldThreshold, 0.5, accuracy: 0.0001)
    }
}
