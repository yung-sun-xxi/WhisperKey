import XCTest
@testable import PasteEngine

final class PasteEngineDecisionTests: XCTestCase {
    func testNilFocusWithoutSecureInputYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(for: nil, secureInputActive: false),
            .paste
        )
    }

    func testNilFocusWithSecureInputYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(for: nil, secureInputActive: true),
            .clipboardOnly
        )
    }

    func testTextFieldYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextField", subrole: nil),
                secureInputActive: false
            ),
            .paste
        )
    }

    func testTextAreaYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextArea", subrole: nil),
                secureInputActive: false
            ),
            .paste
        )
    }

    func testComboBoxYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXComboBox", subrole: nil),
                secureInputActive: false
            ),
            .paste
        )
    }

    func testSecureSubroleOverridesTextFieldRole() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField"),
                secureInputActive: false
            ),
            .clipboardOnly
        )
    }

    func testSecureSubroleAloneYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: nil, subrole: "AXSecureTextField"),
                secureInputActive: false
            ),
            .clipboardOnly
        )
    }

    func testKnownRoleStillPastesEvenWhenSecureInputActive() {
        // OS-level secure-input is a global signal — it can be on for reasons
        // unrelated to the focused field. An explicit non-secure pasteable
        // role should still win.
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextField", subrole: nil),
                secureInputActive: true
            ),
            .paste
        )
    }

    func testUnknownRoleWithoutSecureInputYieldsPaste() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXButton", subrole: nil),
                secureInputActive: false
            ),
            .paste
        )
    }

    func testUnknownRoleWithSecureInputYieldsClipboardOnly() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXButton", subrole: nil),
                secureInputActive: true
            ),
            .clipboardOnly
        )
    }
}

final class PasteEngineAttemptTests: XCTestCase {
    func testKnownRoleFiresKeyboard() {
        let inspector = StubInspector(focus: AXFocusInfo(role: "AXTextField", subrole: nil))
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: false)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .paste)
        XCTAssertEqual(keyboard.callCount, 1)
    }

    func testSecureSubroleSkipsKeyboard() {
        let inspector = StubInspector(focus: AXFocusInfo(role: nil, subrole: "AXSecureTextField"))
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: false)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .clipboardOnly)
        XCTAssertEqual(keyboard.callCount, 0)
    }

    func testNoFocusWithoutSecureInputFiresKeyboard() {
        let inspector = StubInspector(focus: nil)
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: false)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

        let decision = engine.attemptPaste()

        XCTAssertEqual(decision, .paste)
        XCTAssertEqual(keyboard.callCount, 1)
    }

    func testNoFocusWithSecureInputSkipsKeyboard() {
        let inspector = StubInspector(focus: nil)
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: true)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

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

private struct StubProbe: SecureInputProbe {
    let active: Bool
    func isSecureInputActive() -> Bool { active }
}
