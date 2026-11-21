import CoreGraphics
import XCTest
@testable import HotkeyEngine

/// Flag bits spelled out again rather than imported, for the same reason as in
/// `TriggerIdentificationTests`: a test that reads the implementation's own constants
/// cannot catch the implementation changing them.
private enum Bits {
    static let sharedShift: UInt64 = 0x0002_0000
    static let sharedCommand: UInt64 = 0x0010_0000

    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010

    static let noise: UInt64 = 0x0000_0100
}

private enum KeyCode {
    static let leftShift: Int64 = 56
    static let rightShift: Int64 = 60
    static let rightCommand: Int64 = 54
    static let leftControl: Int64 = 59
    static let capsLock: Int64 = 57
    static let letterA: Int64 = 0
    static let arrowUp: Int64 = 126
    static let arrowDown: Int64 = 125
    static let arrowLeft: Int64 = 123
    static let arrowRight: Int64 = 124
}

/// What the event tap makes of the events macOS hands it. The tap itself is not exercised
/// — only the decision it takes, which is the part that has been wrong before.
final class HoldToRevealRunnerTests: XCTestCase {

    private func translate(
        _ type: CGEventType,
        keyCode: Int64,
        rawFlags: UInt64,
        trigger: TriggerKey = .rightCommand
    ) -> HoldToRevealStateMachine.Event? {
        HoldToRevealRunner.translate(
            type: type,
            keyCode: keyCode,
            rawFlags: rawFlags,
            trigger: trigger,
            now: 7.0
        )
    }

    // MARK: - The trigger itself

    func testTriggerPressBecomesTriggerDown() {
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightCommand,
                      rawFlags: Bits.sharedCommand | Bits.rightCommand | Bits.noise),
            .triggerDown(at: 7.0)
        )
    }

    func testTriggerReleaseBecomesTriggerUp() {
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightCommand, rawFlags: Bits.noise),
            .triggerUp(at: 7.0)
        )
    }

    func testTriggerReleaseIsStillATriggerUpWhileTheOtherSideIsHeld() {
        // Left ⌘ down, right ⌘ just up: the shared Command bit is still set. Reading it
        // alone would report a second press and the panel would never close.
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightCommand,
                      rawFlags: Bits.sharedCommand | Bits.leftCommand | Bits.noise),
            .triggerUp(at: 7.0)
        )
    }

    // MARK: - The distinction the gesture depends on

    func testAForeignModifierComingUpIsOtherModifierUp_notOtherKeyDown() {
        // Shift was held before the gesture began and is now released. This must not look
        // like a keystroke, or letting go of Shift would take the panel away.
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.leftShift, rawFlags: Bits.noise),
            .otherModifierUp(at: 7.0)
        )
    }

    func testAForeignModifierGoingDownIsOtherKeyDown() {
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.leftShift,
                      rawFlags: Bits.sharedShift | Bits.leftShift | Bits.noise),
            .otherKeyDown(at: 7.0)
        )
    }

    func testRightShiftComingUpWhileLeftShiftStaysHeldIsStillOtherModifierUp() {
        // The shared Shift bit is still set because the left one is down. The side bits
        // are what tell the two apart.
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightShift,
                      rawFlags: Bits.sharedShift | Bits.leftShift | Bits.noise),
            .otherModifierUp(at: 7.0)
        )
    }

    func testControlComingUpIsOtherModifierUp() {
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.leftControl, rawFlags: Bits.noise),
            .otherModifierUp(at: 7.0)
        )
    }

    func testCapsLockGoingOffIsOtherModifierUp() {
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.capsLock, rawFlags: Bits.noise),
            .otherModifierUp(at: 7.0)
        )
    }

    // MARK: - Ordinary keys still cancel

    func testAnOrdinaryKeyDownIsOtherKeyDown() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.letterA, rawFlags: Bits.noise),
            .otherKeyDown(at: 7.0)
        )
    }

    func testAnUnknownModifierKeyCodeIsTreatedAsAPress() {
        // Conservative: an unrecognised modifier cancels the gesture rather than being
        // silently ignored.
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: 179, rawFlags: Bits.noise),
            .otherKeyDown(at: 7.0)
        )
    }

    func testAnUninterestingEventTypeTranslatesToNothing() {
        XCTAssertNil(translate(.keyUp, keyCode: KeyCode.letterA, rawFlags: Bits.noise))
    }

    // MARK: - Arrow keys are their own event

    func testArrowDownBecomesADownwardArrowEvent() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.arrowDown, rawFlags: Bits.sharedCommand),
            .arrowKeyDown(direction: .down, at: 7.0)
        )
    }

    func testArrowUpBecomesAnUpwardArrowEvent() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.arrowUp, rawFlags: Bits.sharedCommand),
            .arrowKeyDown(direction: .up, at: 7.0)
        )
    }

    func testHorizontalArrowsAreOrdinaryKeysAndStillCancel() {
        // Only up and down steer the list. Left and right have nothing to move, so they
        // keep the old behaviour exactly: cancel the gesture, reach the application.
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.arrowLeft, rawFlags: Bits.noise),
            .otherKeyDown(at: 7.0)
        )
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.arrowRight, rawFlags: Bits.noise),
            .otherKeyDown(at: 7.0)
        )
    }

    func testAKeyUpForAnArrowIsStillNothing() {
        XCTAssertNil(translate(.keyUp, keyCode: KeyCode.arrowDown, rawFlags: Bits.noise))
    }

    // MARK: - What the tap swallows

    func testAnArrowIsSwallowedOnlyWhileThePanelIsUp() {
        let arrow = HoldToRevealStateMachine.Event.arrowKeyDown(direction: .down, at: 7.0)

        XCTAssertTrue(HoldToRevealRunner.consumes(arrow, isRevealed: true))
        XCTAssertFalse(HoldToRevealRunner.consumes(arrow, isRevealed: false))
    }

    func testNothingElseIsEverSwallowed() {
        // The tap stopped being listen-only for the arrows alone. Everything the user
        // types, including the trigger itself, must still reach the application.
        let others: [HoldToRevealStateMachine.Event?] = [
            .triggerDown(at: 7.0),
            .triggerUp(at: 7.0),
            .otherKeyDown(at: 7.0),
            .otherModifierUp(at: 7.0),
            .holdThresholdElapsed(at: 7.0),
            nil,
        ]
        for event in others {
            XCTAssertFalse(HoldToRevealRunner.consumes(event, isRevealed: true),
                           "\(String(describing: event)) must not be swallowed")
            XCTAssertFalse(HoldToRevealRunner.consumes(event, isRevealed: false))
        }
    }

    // MARK: - The trigger is whichever key was configured

    func testTheConfiguredTriggerIsTheOneRecognised() {
        // With right Shift as the trigger, right Command is a foreign modifier.
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightShift,
                      rawFlags: Bits.sharedShift | Bits.rightShift | Bits.noise,
                      trigger: .rightShift),
            .triggerDown(at: 7.0)
        )
        XCTAssertEqual(
            translate(.flagsChanged, keyCode: KeyCode.rightCommand, rawFlags: Bits.noise,
                      trigger: .rightShift),
            .otherModifierUp(at: 7.0)
        )
    }
}
