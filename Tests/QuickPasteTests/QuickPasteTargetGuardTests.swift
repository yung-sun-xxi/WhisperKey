import XCTest
@testable import QuickPaste

final class QuickPasteTargetGuardTests: XCTestCase {

    func testPastesWhenTheFrontmostApplicationIsStillTheOneCaptured() {
        XCTAssertTrue(QuickPasteTargetGuard.shouldPaste(captured: 501, current: 501))
    }

    func testRefusesWhenTheFrontmostApplicationChangedDuringTheHold() {
        XCTAssertFalse(QuickPasteTargetGuard.shouldPaste(captured: 501, current: 777))
    }

    func testRefusesWhenNothingWasCaptured() {
        // Unknown target is not a licence to paste somewhere.
        XCTAssertFalse(QuickPasteTargetGuard.shouldPaste(captured: nil, current: 501))
    }

    func testRefusesWhenThereIsNoFrontmostApplicationAnyMore() {
        XCTAssertFalse(QuickPasteTargetGuard.shouldPaste(captured: 501, current: nil))
    }

    func testRefusesWhenBothEndsAreUnknown() {
        // Two unknowns are not a match, however tempting nil == nil looks.
        XCTAssertFalse(QuickPasteTargetGuard.shouldPaste(captured: nil, current: nil))
    }
}
