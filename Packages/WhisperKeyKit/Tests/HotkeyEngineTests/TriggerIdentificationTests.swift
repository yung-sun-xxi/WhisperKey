import XCTest
@testable import HotkeyEngine

/// Flag bits are spelled out here rather than read from the implementation, so that a
/// change to the implementation's constants shows up as a failure instead of moving
/// the goalposts with itself.
private enum Bits {
    // Side-agnostic CGEventFlags bits (kCGEventFlagMask*).
    static let sharedShift: UInt64 = 0x0002_0000
    static let sharedAlternate: UInt64 = 0x0008_0000
    static let sharedCommand: UInt64 = 0x0010_0000

    // Device-dependent bits carried in the same raw value (NX_DEVICE*KEYMASK).
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040

    /// Bits macOS sets on essentially every event and which must not influence the decision.
    static let noise: UInt64 = 0x0000_0100
}

final class TriggerIdentificationTests: XCTestCase {

    // MARK: - The regression this exists for

    func testRightCommandReleaseIsARelease_whileLeftCommandStaysHeld() {
        // Left ⌘ still down, right ⌘ just came up: the shared Command bit is still set.
        let flags = Bits.sharedCommand | Bits.leftCommand | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .released)
    }

    func testRightOptionReleaseIsARelease_whileLeftOptionStaysHeld() {
        let flags = Bits.sharedAlternate | Bits.leftOption | Bits.noise

        XCTAssertEqual(TriggerKey.rightOption.transition(rawFlags: flags), .released)
    }

    func testRightShiftReleaseIsARelease_whileLeftShiftStaysHeld() {
        let flags = Bits.sharedShift | Bits.leftShift | Bits.noise

        XCTAssertEqual(TriggerKey.rightShift.transition(rawFlags: flags), .released)
    }

    // MARK: - Presses are still presses

    func testRightCommandPressWhileLeftCommandHeldIsAPress() {
        let flags = Bits.sharedCommand | Bits.leftCommand | Bits.rightCommand | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .pressed)
    }

    func testRightCommandPressAloneIsAPress() {
        let flags = Bits.sharedCommand | Bits.rightCommand | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .pressed)
    }

    func testRightOptionPressAloneIsAPress() {
        let flags = Bits.sharedAlternate | Bits.rightOption | Bits.noise

        XCTAssertEqual(TriggerKey.rightOption.transition(rawFlags: flags), .pressed)
    }

    func testRightShiftPressAloneIsAPress() {
        let flags = Bits.sharedShift | Bits.rightShift | Bits.noise

        XCTAssertEqual(TriggerKey.rightShift.transition(rawFlags: flags), .pressed)
    }

    // MARK: - Releases with nothing else held

    func testRightCommandReleaseAloneIsARelease() {
        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: Bits.noise), .released)
    }

    func testRightOptionReleaseAloneIsARelease() {
        XCTAssertEqual(TriggerKey.rightOption.transition(rawFlags: Bits.noise), .released)
    }

    // MARK: - A different modifier family never speaks for this one

    func testHeldLeftShiftDoesNotMakeRightCommandLookPressed() {
        let flags = Bits.sharedShift | Bits.leftShift | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .released)
    }

    func testHeldRightOptionDoesNotMakeRightCommandLookPressed() {
        let flags = Bits.sharedAlternate | Bits.rightOption | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .released)
    }

    // MARK: - Fallback when a device reports no side bits at all

    func testSharedBitAloneStillCountsAsPressed() {
        // Some keyboards and every synthesised event report only the side-agnostic bit.
        // Without side information the old, shared-mask answer is the best available one.
        let flags = Bits.sharedCommand | Bits.noise

        XCTAssertEqual(TriggerKey.rightCommand.transition(rawFlags: flags), .pressed)
    }

    func testSharedAlternateBitAloneStillCountsAsPressed() {
        XCTAssertEqual(
            TriggerKey.rightOption.transition(rawFlags: Bits.sharedAlternate | Bits.noise),
            .pressed
        )
    }

    // MARK: - Every trigger, both directions, in one sweep

    func testEveryTriggerIsReleasedWhenItsOwnSideBitIsClearAndTheOtherSideIsHeld() {
        let cases: [(TriggerKey, UInt64)] = [
            (.rightCommand, Bits.sharedCommand | Bits.leftCommand),
            (.rightOption, Bits.sharedAlternate | Bits.leftOption),
            (.rightShift, Bits.sharedShift | Bits.leftShift),
        ]

        for (trigger, flags) in cases {
            XCTAssertEqual(
                trigger.transition(rawFlags: flags | Bits.noise),
                .released,
                "\(trigger) should read as released"
            )
        }
    }
}
