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

/// Refusing a secure text field is a property of the *caller*, not of the engine.
///
/// The transcription auto-paste fires on its own when a transcription lands, so a caret
/// that happens to sit in a password field must not receive a dictated sentence. The
/// quick-paste popup is the opposite: the user held a key, looked at a list, pointed at
/// one entry and released, and pasting a password is one of the things he wants it for.
///
/// A caller that says nothing gets the refusal. That default is what keeps every existing
/// call site — the transcription path included — behaving exactly as it did.
final class PasteEngineSecureFieldPolicyTests: XCTestCase {
    private let secureField = AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")

    // MARK: The default

    func testACallerThatSaysNothingStillRefusesASecureField() {
        XCTAssertEqual(
            PasteEngine.decide(for: secureField, secureInputActive: false),
            .clipboardOnly
        )
    }

    func testTheRefusingPolicyRefusesASecureField() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: secureField,
                secureInputActive: false,
                secureFieldPolicy: .refuse
            ),
            .clipboardOnly
        )
    }

    // MARK: The permissive policy

    func testTheAllowingPolicyPastesIntoASecureField() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: secureField,
                secureInputActive: false,
                secureFieldPolicy: .allow
            ),
            .paste
        )
    }

    /// A real password field almost always has macOS secure input switched on. Were the
    /// secure subrole merely *ignored* rather than treated as a known text field, the
    /// unknown-role probe would refuse and the popup would still paste nothing.
    func testTheAllowingPolicyPastesIntoASecureFieldWhileSecureInputIsActive() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: secureField,
                secureInputActive: true,
                secureFieldPolicy: .allow
            ),
            .paste
        )
    }

    /// Some applications expose the subrole without a role. It is still a positive
    /// identification of a text field.
    func testTheAllowingPolicyPastesIntoASecureSubroleWithNoRole() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: nil, subrole: "AXSecureTextField"),
                secureInputActive: true,
                secureFieldPolicy: .allow
            ),
            .paste
        )
    }

    // MARK: The rest of the matrix is untouched by the policy

    /// The Electron path: no AX role at all. The secure-input probe is the only guard
    /// left there, and allowing labelled secure fields must not remove it.
    func testTheAllowingPolicyStillRefusesAnUnidentifiedFieldWhileSecureInputIsActive() {
        XCTAssertEqual(
            PasteEngine.decide(for: nil, secureInputActive: true, secureFieldPolicy: .allow),
            .clipboardOnly
        )
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXButton", subrole: nil),
                secureInputActive: true,
                secureFieldPolicy: .allow
            ),
            .clipboardOnly
        )
    }

    func testTheAllowingPolicyLeavesTheKnownRoleBranchAlone() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextField", subrole: nil),
                secureInputActive: true,
                secureFieldPolicy: .allow
            ),
            .paste
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

    /// The route the popup needs: `attemptPaste` has to carry the caller's policy through
    /// to `decide`, or the pure function's parameter is unreachable from the real app.
    func testSecureSubroleFiresKeyboardWhenTheCallerAllowsIt() {
        let inspector = StubInspector(focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField"))
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: true)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

        let decision = engine.attemptPaste(secureFieldPolicy: .allow)

        XCTAssertEqual(decision, .paste)
        XCTAssertEqual(keyboard.callCount, 1)
    }

    func testSecureSubroleSkipsKeyboardWhenTheCallerAsksToRefuse() {
        let inspector = StubInspector(focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField"))
        let keyboard = SpyKeyboard()
        let probe = StubProbe(active: false)
        let engine = PasteEngine(inspector: inspector, keyboard: keyboard, secureProbe: probe)

        let decision = engine.attemptPaste(secureFieldPolicy: .refuse)

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

    func testCancelledDeliveryDoesNotTouchClipboardOrPaste() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard)

        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            return await router.deliver(
                text: "hello",
                settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true)
            )
        }
        task.cancel()

        let result = await task.value

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

    /// The transcription auto-paste passes no policy, and must keep refusing. This is the
    /// regression proof for the default: it is the transcription's own call shape.
    func testDeliveryThatNamesNoPolicyRefusesToPasteIntoASecureField() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")
        )

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
        )

        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(result.pasteDecision, .clipboardOnly)
        XCTAssertEqual(pasteboard.currentString, "previous")
    }

    /// The route the quick-paste popup uses.
    func testDeliveryThatAllowsSecureFieldsPastesIntoOne() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")
        )

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true),
            secureFieldPolicy: .allow
        )

        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(result.pasteDecision, .paste)
        // Still the popup's contract: the clipboard is left as the user had it.
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
    }

    /// The `saveToClipboard: true` branch has its own paste call and needs the same route.
    func testDeliveryThatAllowsSecureFieldsAlsoAppliesWhenTheClipboardIsKept() async {
        let pasteboard = SpyPasteboard(currentString: "previous")
        let keyboard = SpyKeyboard()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")
        )

        let result = await router.deliver(
            text: "hello",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true),
            secureFieldPolicy: .allow
        )

        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(result.pasteDecision, .paste)
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
