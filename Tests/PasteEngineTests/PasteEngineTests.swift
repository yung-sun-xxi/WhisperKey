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

final class TranscriptionOutputRouterTests: XCTestCase {
    func testClipboardOnlyWritesClipboardAndSkipsPaste() async {
        let pasteboard = SpyPasteboard()
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: false)
        )

        XCTAssertEqual(pasteboard.currentString, "hello")
        XCTAssertEqual(pasteboard.replaceCallCount, 1)
        XCTAssertEqual(pasteboard.snapshotCallCount, 0)
        XCTAssertEqual(pasteboard.restoreCallCount, 0)
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: nil,
            restoredClipboard: false
        ))
    }

    func testAutoPasteOnlyTemporarilyWritesClipboardThenRestoresPreviousValue() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
        )

        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.replaceCallCount, 1)
        XCTAssertEqual(pasteboard.snapshotCallCount, 1)
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .paste,
            restoredClipboard: true
        ))
    }

    func testBothEnabledWritesClipboardAndAttemptsPasteWithoutRestoring() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true)
        )

        XCTAssertEqual(pasteboard.currentString, "hello")
        XCTAssertEqual(pasteboard.replaceCallCount, 1)
        XCTAssertEqual(pasteboard.snapshotCallCount, 0)
        XCTAssertEqual(pasteboard.restoreCallCount, 0)
        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .paste,
            restoredClipboard: false
        ))
    }

    func testNeitherEnabledDoesNotTouchClipboardOrPaste() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: false)
        )

        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.replaceCallCount, 0)
        XCTAssertEqual(pasteboard.snapshotCallCount, 0)
        XCTAssertEqual(pasteboard.restoreCallCount, 0)
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: false,
            pasteDecision: nil,
            restoredClipboard: false
        ))
    }

    func testAutoPasteOnlyRestoresClipboardWhenPasteIsBlocked() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            focus: AXFocusInfo(role: nil, subrole: "AXSecureTextField")
        )

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
        )

        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .clipboardOnly,
            restoredClipboard: true
        ))
    }

    func testAutoPasteOnlySkipsPasteAndRestoresClipboardWhenClipboardWriteFails() async {
        let pasteboard = SpyPasteboard(currentString: "previous", replaceSucceeds: false)
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
        )

        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.replaceCallCount, 1)
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: false,
            pasteDecision: nil,
            restoredClipboard: true
        ))
    }

    private func makeRouter(
        pasteboard: SpyPasteboard,
        keyboard: SpyKeyboard,
        focus: AXFocusInfo? = AXFocusInfo(role: "AXTextField", subrole: nil)
    ) -> TranscriptionOutputRouter {
        let engine = PasteEngine(
            inspector: StubInspector(focus: focus),
            keyboard: keyboard,
            secureProbe: StubProbe(active: false)
        )
        return TranscriptionOutputRouter(
            pasteEngine: engine,
            pasteboard: pasteboard,
            restoreDelayNanoseconds: 0
        )
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

private final class SpyPasteboard: TranscriptionPasteboard {
    var currentString: String?
    private(set) var snapshotCallCount = 0
    private(set) var replaceCallCount = 0
    private(set) var restoreCallCount = 0
    private let replaceSucceeds: Bool

    init(currentString: String? = nil, replaceSucceeds: Bool = true) {
        self.currentString = currentString
        self.replaceSucceeds = replaceSucceeds
    }

    func snapshot() -> PasteboardSnapshot {
        snapshotCallCount += 1
        return Self.snapshot(for: currentString)
    }

    func replaceWithString(_ string: String) -> Bool {
        replaceCallCount += 1
        guard replaceSucceeds else {
            currentString = nil
            return false
        }
        currentString = string
        return true
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        restoreCallCount += 1
        currentString = Self.string(from: snapshot)
        return true
    }

    private static func snapshot(for string: String?) -> PasteboardSnapshot {
        guard let string else {
            return PasteboardSnapshot(items: [])
        }
        return PasteboardSnapshot(items: [
            [.string: Data(string.utf8)]
        ])
    }

    private static func string(from snapshot: PasteboardSnapshot) -> String? {
        guard
            let data = snapshot.items.first?[.string],
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }
}
