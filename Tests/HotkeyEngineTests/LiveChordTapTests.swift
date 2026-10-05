import CoreGraphics
import XCTest
@testable import HotkeyEngine

/// Event type bits, flag bits and key codes spelled out again rather than imported: a test
/// that reads the implementation's own constants cannot catch the implementation changing
/// them.
private enum TypeBit {
    static let keyDown: CGEventMask = 1 << 10
    static let keyUp: CGEventMask = 1 << 11
    static let flagsChanged: CGEventMask = 1 << 12
}

private enum Bits {
    static let sharedOption: UInt64 = 0x0008_0000
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let noise: UInt64 = 0x0000_0100
}

private enum KeyCode {
    static let rightOption: Int64 = 61
    static let leftShift: Int64 = 56
    static let slash: Int64 = 44
    static let letterA: Int64 = 0
    static let escape: Int64 = 53
}

/// What the Live-aware event tap decides, with the tap taken out: how it is created, what
/// each `CGEvent` becomes for the state machine, and which keystrokes it swallows.
final class LiveChordTapTests: XCTestCase {

    private let disabled = HotkeyConfig(trigger: .rightOption, mode: .tap, liveEnabled: false)
    private let enabled = HotkeyConfig(trigger: .rightOption, mode: .tap, liveEnabled: true)
    private let holdEnabled = HotkeyConfig(trigger: .rightOption, mode: .hold, liveEnabled: true)

    // MARK: - Tap configuration

    func testLiveDisabledTapIsTodaysListenOnlyTapOnTheMainRunLoop() {
        for mode in TriggerMode.allCases {
            let setup = HotkeyEngineRunner.tapSetup(
                for: HotkeyConfig(trigger: .rightOption, mode: mode, liveEnabled: false)
            )
            XCTAssertEqual(setup.options, .listenOnly, "\(mode)")
            XCTAssertEqual(setup.mask, TypeBit.flagsChanged | TypeBit.keyDown, "\(mode)")
            XCTAssertEqual(setup.runLoop, .main, "\(mode)")
        }
    }

    func testLiveEnabledTapIsActiveSeesKeyUpAndRunsOnItsOwnThread() {
        for mode in TriggerMode.allCases {
            let setup = HotkeyEngineRunner.tapSetup(
                for: HotkeyConfig(trigger: .rightOption, mode: mode, liveEnabled: true)
            )
            XCTAssertEqual(setup.options, .defaultTap, "\(mode)")
            XCTAssertEqual(setup.mask, TypeBit.flagsChanged | TypeBit.keyDown | TypeBit.keyUp,
                           "\(mode)")
            XCTAssertEqual(setup.runLoop, .dedicatedThread, "\(mode)")
        }
    }

    func testTheChordKeyCodeDoesNotChangeTheTap() {
        var config = enabled
        config.liveChordKeyCode = KeyCode.letterA
        XCTAssertEqual(HotkeyEngineRunner.tapSetup(for: config),
                       HotkeyEngineRunner.tapSetup(for: enabled))
    }

    // MARK: - Translation

    private func translate(
        _ type: CGEventType,
        keyCode: Int64,
        rawFlags: UInt64 = Bits.noise,
        isAutorepeat: Bool = false,
        triggerHeld: Bool = false,
        config: HotkeyConfig
    ) -> HotkeyStateMachine.Event? {
        HotkeyEngineRunner.translate(
            type: type,
            keyCode: keyCode,
            rawFlags: rawFlags,
            isAutorepeat: isAutorepeat,
            triggerHeld: triggerHeld,
            config: config,
            now: 7.0
        )
    }

    func testLiveDisabledTranslationIsTodays() {
        // Today's runner: the trigger's flagsChanged is down or up by its flags, any other
        // flagsChanged is "another key", Escape is Escape, every other keyDown — repeats
        // included — is "another key", and nothing else is an event.
        for held in [false, true] {
            XCTAssertEqual(
                translate(.flagsChanged, keyCode: KeyCode.rightOption,
                          rawFlags: Bits.sharedOption | Bits.rightOption, triggerHeld: held,
                          config: disabled),
                .triggerDown(at: 7.0))
            XCTAssertEqual(
                translate(.flagsChanged, keyCode: KeyCode.rightOption, triggerHeld: held,
                          config: disabled),
                .triggerUp(at: 7.0))
            XCTAssertEqual(
                translate(.flagsChanged, keyCode: KeyCode.leftShift, triggerHeld: held,
                          config: disabled),
                .otherKeyDown(at: 7.0))
            XCTAssertEqual(
                translate(.keyDown, keyCode: KeyCode.escape, triggerHeld: held, config: disabled),
                .escapeDown(at: 7.0))
            for repeating in [false, true] {
                XCTAssertEqual(
                    translate(.keyDown, keyCode: KeyCode.slash, isAutorepeat: repeating,
                              triggerHeld: held, config: disabled),
                    .otherKeyDown(at: 7.0))
                XCTAssertEqual(
                    translate(.keyDown, keyCode: KeyCode.letterA, isAutorepeat: repeating,
                              triggerHeld: held, config: disabled),
                    .otherKeyDown(at: 7.0))
            }
            XCTAssertNil(translate(.keyUp, keyCode: KeyCode.slash, triggerHeld: held,
                                   config: disabled))
        }
    }

    func testChordKeyDownWithTheTriggerHeldIsAChordEvent() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.slash, triggerHeld: true, config: enabled),
            .chordKeyDown(at: 7.0))
    }

    func testChordKeyAutoRepeatIsItsOwnEvent() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.slash, isAutorepeat: true, triggerHeld: true,
                      config: enabled),
            .chordKeyRepeat(at: 7.0))
    }

    func testChordKeyWithoutTheTriggerHeldIsAnOrdinaryKey() {
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.slash, triggerHeld: false, config: enabled),
            .otherKeyDown(at: 7.0))
    }

    func testTheConfiguredChordKeyIsTheOneRecognised() {
        var config = enabled
        config.liveChordKeyCode = KeyCode.letterA
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.letterA, triggerHeld: true, config: config),
            .chordKeyDown(at: 7.0))
        XCTAssertEqual(
            translate(.keyDown, keyCode: KeyCode.slash, triggerHeld: true, config: config),
            .otherKeyDown(at: 7.0))
    }

    func testKeyUpIsNeverAnEventForTheStateMachine() {
        XCTAssertNil(translate(.keyUp, keyCode: KeyCode.slash, triggerHeld: true, config: enabled))
        XCTAssertNil(translate(.keyUp, keyCode: KeyCode.letterA, triggerHeld: true, config: enabled))
    }

    // MARK: - Is the trigger held?

    func testTriggerHeldNeedsBothTheTrackedPressAndTheFlagOnTheKeystroke() {
        let flagsHeld = Bits.sharedOption | Bits.rightOption | Bits.noise
        XCTAssertTrue(HotkeyEngineRunner.isTriggerHeld(
            tracked: true, rawFlags: flagsHeld, trigger: .rightOption))
        // A missed release (the tap was disabled for a moment): the keystroke's own flags
        // say the key is up, so `/` is typed normally.
        XCTAssertFalse(HotkeyEngineRunner.isTriggerHeld(
            tracked: true, rawFlags: Bits.noise, trigger: .rightOption))
        // Left Option held, right Option tracked up: the other side's bit is not ours.
        XCTAssertFalse(HotkeyEngineRunner.isTriggerHeld(
            tracked: true, rawFlags: Bits.sharedOption | Bits.leftOption, trigger: .rightOption))
        // The flags say Option is down but no trigger press was seen.
        XCTAssertFalse(HotkeyEngineRunner.isTriggerHeld(
            tracked: false, rawFlags: flagsHeld, trigger: .rightOption))
    }

    // MARK: - What the tap swallows

    /// Feeds a sequence of keystrokes through `consumes`, carrying its state along the way
    /// as the runner does, and returns the swallow decision for each.
    private func swallowed(
        _ steps: [(CGEventType, Int64, Bool, Bool)],   // type, key code, autorepeat, trigger held
        config: HotkeyConfig
    ) -> [Bool] {
        var owed = false
        return steps.map { type, keyCode, repeating, held in
            HotkeyEngineRunner.consumes(
                type: type,
                keyCode: keyCode,
                isAutorepeat: repeating,
                triggerHeld: held,
                config: config,
                chordKeyOwed: &owed
            )
        }
    }

    private let chordSequence: [(CGEventType, Int64, Bool, Bool)] = [
        (.flagsChanged, KeyCode.rightOption, false, true),   // trigger down
        (.keyDown, KeyCode.slash, false, true),              // chord
        (.keyDown, KeyCode.slash, true, true),               // auto-repeat
        (.keyDown, KeyCode.slash, true, true),               // auto-repeat
        (.keyUp, KeyCode.slash, false, true),                // chord key up
        (.flagsChanged, KeyCode.rightOption, false, false),  // trigger up
    ]

    func testLiveDisabledSwallowsNothing() {
        XCTAssertEqual(swallowed(chordSequence, config: disabled),
                       [false, false, false, false, false, false])
    }

    func testHoldModeSwallowsNothingYet() {
        XCTAssertEqual(swallowed(chordSequence, config: holdEnabled),
                       [false, false, false, false, false, false])
    }

    func testTheChordKeyDownItsRepeatsAndItsKeyUpAreSwallowed() {
        XCTAssertEqual(swallowed(chordSequence, config: enabled),
                       [false, true, true, true, true, false])
    }

    func testTheChordKeyUpIsSwallowedEvenAfterTheTriggerWasReleased() {
        let steps: [(CGEventType, Int64, Bool, Bool)] = [
            (.keyDown, KeyCode.slash, false, true),
            (.flagsChanged, KeyCode.rightOption, false, false),  // trigger up first
            (.keyDown, KeyCode.slash, true, false),              // still repeating
            (.keyUp, KeyCode.slash, false, false),
            // The next ordinary `/` is typed.
            (.keyDown, KeyCode.slash, false, false),
            (.keyUp, KeyCode.slash, false, false),
        ]
        XCTAssertEqual(swallowed(steps, config: enabled),
                       [true, false, true, true, false, false])
    }

    func testAChordKeyPressedWithoutTheTriggerIsTypedWithItsRepeatsAndKeyUp() {
        let steps: [(CGEventType, Int64, Bool, Bool)] = [
            (.keyDown, KeyCode.slash, false, false),
            (.flagsChanged, KeyCode.rightOption, false, true),   // trigger down mid-hold
            (.keyDown, KeyCode.slash, true, true),               // repeats of a typed `/`
            (.keyUp, KeyCode.slash, false, true),
        ]
        XCTAssertEqual(swallowed(steps, config: enabled), [false, false, false, false])
    }

    func testNothingButTheChordKeyIsEverSwallowed() {
        // Other keys, Escape, the trigger itself: never, held trigger or not.
        for held in [false, true] {
            let steps: [(CGEventType, Int64, Bool, Bool)] = [
                (.flagsChanged, KeyCode.rightOption, false, held),
                (.flagsChanged, KeyCode.leftShift, false, held),
                (.keyDown, KeyCode.letterA, false, held),
                (.keyDown, KeyCode.letterA, true, held),
                (.keyUp, KeyCode.letterA, false, held),
                (.keyDown, KeyCode.escape, false, held),
                (.keyUp, KeyCode.escape, false, held),
            ]
            XCTAssertEqual(swallowed(steps, config: enabled),
                           Array(repeating: false, count: steps.count), "held: \(held)")
        }
    }

    func testAnUnrelatedKeyUpDoesNotSettleTheChordKeysDebt() {
        let steps: [(CGEventType, Int64, Bool, Bool)] = [
            (.keyDown, KeyCode.slash, false, true),
            (.keyUp, KeyCode.letterA, false, true),
            (.keyUp, KeyCode.slash, false, false),
        ]
        XCTAssertEqual(swallowed(steps, config: enabled), [true, false, true])
    }

    func testTheChordKeyIsSwallowedWhileTheTriggerIsHeldWhateverTheAppIsDoing() {
        // While recording the chord acts as the plain trigger, and the `/` must still not
        // reach the application: the policy depends on the trigger, not on app state, so
        // there is nothing about recording to pass in.
        XCTAssertTrue(swallowed([(.keyDown, KeyCode.slash, false, true)], config: enabled)[0])
    }
}
