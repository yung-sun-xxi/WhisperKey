import XCTest
@testable import PasteEngine

final class PasteEngineDecisionTests: XCTestCase {
    func testNilFocusYieldsClipboardOnly() {
        XCTAssertEqual(PasteEngine.decide(for: nil), .clipboardOnly)
    }

    func testTextFieldYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: "AXTextField", subrole: nil)),
            .paste
        )
    }

    func testTextAreaYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: "AXTextArea", subrole: nil)),
            .paste
        )
    }

    func testComboBoxYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: "AXComboBox", subrole: nil)),
            .paste
        )
    }

    func testSecureSubroleOverridesTextFieldRole() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")),
            .clipboardOnly
        )
    }

    func testSecureSubroleAloneYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: nil, subrole: "AXSecureTextField")),
            .clipboardOnly
        )
    }

    func testButtonRoleYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: "AXButton", subrole: nil)),
            .clipboardOnly
        )
    }

    func testNilRoleAndSubroleYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(for: AXFocusInfo(role: nil, subrole: nil)),
            .clipboardOnly
        )
    }
}

final class PasteEngineAttemptTests: XCTestCase {
    func testPasteFiresKeyboardWhenDecisionIsPaste() {
        let inspector = StubInspector(focus: AXFocusInfo(role: "AXTextField", subrole: nil))
        let keyboard = SpyKeyboard()
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .paste)
        XCTAssertEqual(keyboard.callCount, 1)
    }

    func testClipboardOnlySkipsKeyboard() {
        let inspector = StubInspector(focus: AXFocusInfo(role: nil, subrole: "AXSecureTextField"))
        let keyboard = SpyKeyboard()
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .clipboardOnly)
        XCTAssertEqual(keyboard.callCount, 0)
    }

    func testNoFocusSkipsKeyboard() {
        let inspector = StubInspector(focus: nil)
        let keyboard = SpyKeyboard()
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .clipboardOnly)
        XCTAssertEqual(keyboard.callCount, 0)
    }
}

private struct StubInspector: AXFocusInspector {
    let focus: AXFocusInfo?
    func currentFocus() -> AXFocusInfo? { focus }
}

private final class SpyKeyboard: KeyboardSimulator, @unchecked Sendable {
    private(set) var callCount = 0
    func sendCommandV() { callCount += 1 }
}
