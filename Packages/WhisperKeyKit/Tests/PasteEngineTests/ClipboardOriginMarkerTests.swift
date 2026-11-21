import AppKit
import XCTest
@testable import ClipboardHistoryStore
@testable import PasteEngine

/// Origin attribution end to end: what the clipboard-output path writes is what the
/// clipboard monitor reads back.
///
/// These run against a *named* `NSPasteboard` created for the test, never
/// `NSPasteboard.general`. Nothing here touches the user's clipboard, and nothing here
/// depends on what is on it.
final class ClipboardOriginMarkerTests: XCTestCase {

    private var board: NSPasteboard!
    private var captures: [(text: String, origin: ClipboardEntryOrigin)] = []
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: NSPasteboard.Name("WhisperKeyOriginTests-\(UUID().uuidString)"))
        board.clearContents()
        captures = []
        monitor = ClipboardMonitor(pasteboard: SystemClipboardReader(pasteboard: board)) { [weak self] text, origin, _ in
            self?.captures.append((text, origin))
        }
        monitor.start()
    }

    override func tearDown() {
        monitor?.stop()
        monitor = nil
        board?.releaseGlobally()
        board = nil
        super.tearDown()
    }

    /// The `saveToClipboard: true` configuration writes on a path where the monitor is
    /// *not* suspended. Unmarked, the transcription would be recorded as a hand copy.
    func testTranscriptionKeptOnTheClipboardIsAttributedToWhisperKey() async {
        let router = TranscriptionOutputRouter(
            pasteEngine: PasteEngine(
                inspector: StubFocusInspector(focus: nil),
                keyboard: NoopKeyboard(),
                secureProbe: StubSecureInput(active: true)
            ),
            pasteboard: SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0
        )

        let result = await router.deliver(
            text: "a dictated sentence",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: false)
        )
        XCTAssertTrue(result.wroteClipboard)

        monitor.poll()

        XCTAssertEqual(captures.map(\.text), ["a dictated sentence"])
        XCTAssertEqual(captures.map(\.origin), [.whisperKey])
    }

    func testTextCopiedByAnotherApplicationIsNotAttributedToWhisperKey() {
        board.clearContents()
        board.setString("copied by hand", forType: .string)

        monitor.poll()

        XCTAssertEqual(captures.map(\.text), ["copied by hand"])
        XCTAssertEqual(captures.map(\.origin), [.otherApplication])
    }

    /// The marker must not survive into the restored clipboard: the snapshot is taken
    /// before WhisperKey writes, so what comes back is the user's own unmarked item.
    func testRestoringTheClipboardAfterAnAutoPasteLeavesItUnmarked() {
        board.clearContents()
        board.setString("what the user copied", forType: .string)

        let pasteboard = SystemTranscriptionPasteboard(pasteboard: board)
        let snapshot = pasteboard.snapshot()
        XCTAssertTrue(pasteboard.replaceWithString("a dictated sentence"))
        XCTAssertTrue(pasteboard.restore(snapshot))

        monitor.poll()

        XCTAssertEqual(captures.map(\.text), ["what the user copied"])
        XCTAssertEqual(captures.map(\.origin), [.otherApplication])
    }

    func testTheWrittenStringItselfIsUnchangedByTheMarker() {
        let pasteboard = SystemTranscriptionPasteboard(pasteboard: board)
        XCTAssertTrue(pasteboard.replaceWithString("plain text, nothing else"))

        XCTAssertEqual(board.string(forType: .string), "plain text, nothing else")
    }
}

private struct StubFocusInspector: AXFocusInspector {
    let focus: AXFocusInfo?
    func currentFocus() -> AXFocusInfo? { focus }
}

private final class NoopKeyboard: KeyboardSimulator, @unchecked Sendable {
    func sendCommandV() {}
}

private struct StubSecureInput: SecureInputProbe {
    let active: Bool
    func isSecureInputActive() -> Bool { active }
}
