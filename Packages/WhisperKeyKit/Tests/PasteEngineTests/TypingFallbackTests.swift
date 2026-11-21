import AppKit
import CoreGraphics
import XCTest
@testable import ClipboardHistoryStore
@testable import PasteEngine

/// The auto-paste typing fallback (#215): with `saveToClipboard: false, autoPaste: true`
/// and files on the clipboard, the transcript is typed and the clipboard never touched.
///
/// A Finder copy from a TCC-protected folder cannot be restored by WhisperKey: pboard
/// drops the `public.file-url` it writes back, and the next ⌘V pastes the file's name and
/// icon instead of the file. Typing leaves nothing to restore.
final class TypingFallbackRouterTests: XCTestCase {

    // MARK: - Which path

    func testFilesOnTheClipboardAreLeftAloneAndTheTranscriptIsTyped() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let keyboard = CountingKeyboard()
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard, typer: typer)

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(typer.typed, ["dictated"])
        XCTAssertEqual(keyboard.callCount, 0, "⌘V sent on the typed path")
        XCTAssertEqual(pasteboard.writeCallCount, 0, "the clipboard was written")
        XCTAssertEqual(pasteboard.restoreCallCount, 0, "the clipboard was restored")
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: false,
            pasteDecision: .paste,
            restoredClipboard: false,
            delivery: .typed
        ))
        XCTAssertTrue(result.autoPasted)
    }

    /// Any item with a file URL is enough: a Finder copy of several files, or one mixed in.
    func testAFileURLOnAnyItemChoosesTyping() async {
        let pasteboard = FakePasteboard(items: [Self.plainText, Self.finderFileCopy])
        let keyboard = CountingKeyboard()
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard, typer: typer)

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(typer.typed, ["dictated"])
        XCTAssertEqual(pasteboard.writeCallCount, 0)
        XCTAssertEqual(result.delivery, .typed)
    }

    func testTextOnTheClipboardKeepsTheSwap() async {
        await assertSwap(for: [Self.plainText])
    }

    /// An image copied as image data (a screenshot to the clipboard, "Copy Image" in a
    /// browser) carries no file URL and is restored fine today.
    func testAnImageCopiedAsDataKeepsTheSwap() async {
        await assertSwap(for: [[.png: Data([0x89, 0x50, 0x4E, 0x47]), .tiff: Data([0x4D, 0x4D])]])
    }

    func testAnEmptyClipboardKeepsTheSwap() async {
        await assertSwap(for: [])
    }

    /// The transcript is meant to stay on the clipboard here; the user's files are
    /// replaced on purpose, as before.
    func testKeepingTheTranscriptOnTheClipboardNeverTypes() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let keyboard = CountingKeyboard()
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard, typer: typer)

        let result = await router.deliver(
            text: "dictated",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true)
        )

        XCTAssertEqual(typer.typed, [])
        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(pasteboard.writeCallCount, 1)
        XCTAssertEqual(result.delivery, .clipboard)
    }

    /// The quick-paste popup's shape: a router built without a typer never types, files
    /// or not. Its entries are often multi-line, and typing would flatten them.
    func testARouterWithoutATyperKeepsTheSwapEvenWithFiles() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let keyboard = CountingKeyboard()
        let router = TranscriptionOutputRouter(
            pasteEngine: makeEngine(keyboard: keyboard),
            pasteboard: pasteboard,
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 1_000_000
        )

        let result = await router.deliver(
            text: "an older entry",
            settings: .autoPasteOnly,
            secureFieldPolicy: .allow
        )

        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertEqual(pasteboard.writeCallCount, 1)
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
        XCTAssertEqual(result.delivery, .clipboard)
    }

    // MARK: - What is typed

    /// A typed newline is Return, and Return sends the message in a chat app.
    func testLineBreaksAreTypedAsSpaces() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: CountingKeyboard(), typer: typer)

        await router.deliver(
            text: "one\ntwo\r\nthree\rfour\u{2028}five\u{2029}six",
            settings: .autoPasteOnly
        )

        XCTAssertEqual(typer.typed, ["one two three four five six"])
    }

    // MARK: - The paste decision still applies

    func testAFieldLabelledSecureGetsNothingTyped() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let keyboard = CountingKeyboard()
        let typer = RecordingTyper()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            typer: typer,
            focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")
        )

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(typer.typed, [])
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(pasteboard.writeCallCount, 0)
        XCTAssertEqual(pasteboard.restoreCallCount, 0)
        XCTAssertEqual(result.pasteDecision, .clipboardOnly)
        XCTAssertEqual(result.delivery, .typed)
        XCTAssertFalse(result.autoPasted)
    }

    /// An Electron field publishes no role; system secure input is what refuses there.
    func testSecureInputWithAnUnknownRoleGetsNothingTyped() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let typer = RecordingTyper()
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: CountingKeyboard(),
            typer: typer,
            focus: nil,
            secureInputActive: true
        )

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(typer.typed, [])
        XCTAssertEqual(result.pasteDecision, .clipboardOnly)
    }

    func testACancelledDeliveryTypesNothing() async {
        let pasteboard = FakePasteboard(items: [Self.finderFileCopy])
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: CountingKeyboard(), typer: typer)

        let task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            return await router.deliver(text: "dictated", settings: .autoPasteOnly)
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(typer.typed, [])
        XCTAssertNil(result.pasteDecision)
    }

    // MARK: - Helpers

    static let plainText: [NSPasteboard.PasteboardType: Data] = [.string: Data("copied".utf8)]

    /// What Finder puts on the clipboard for one copied file: the URL, the name as text
    /// twice, and the icon.
    static let finderFileCopy: [NSPasteboard.PasteboardType: Data] = [
        .fileURL: Data("file:///.file/id=6571367.789514".utf8),
        .string: Data("Screenshot 2026-11-17 at 18.31.28".utf8),
        NSPasteboard.PasteboardType("public.utf16-external-plain-text"): Data([0xFF, 0xFE]),
        NSPasteboard.PasteboardType("com.apple.icns"): Data([0x69, 0x63, 0x6E, 0x73]),
    ]

    private func assertSwap(
        for items: [[NSPasteboard.PasteboardType: Data]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let pasteboard = FakePasteboard(items: items)
        let keyboard = CountingKeyboard()
        let typer = RecordingTyper()
        let router = makeRouter(pasteboard: pasteboard, keyboard: keyboard, typer: typer)

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(typer.typed, [], file: file, line: line)
        XCTAssertEqual(keyboard.callCount, 1, file: file, line: line)
        XCTAssertEqual(pasteboard.writeCallCount, 1, file: file, line: line)
        XCTAssertEqual(pasteboard.restoreCallCount, 1, file: file, line: line)
        XCTAssertEqual(pasteboard.items, items, "the clipboard was not put back", file: file, line: line)
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .paste,
            restoredClipboard: true,
            delivery: .clipboard
        ), file: file, line: line)
    }

    private func makeEngine(
        keyboard: CountingKeyboard,
        focus: AXFocusInfo? = AXFocusInfo(role: "AXTextField", subrole: nil),
        secureInputActive: Bool = false
    ) -> PasteEngine {
        PasteEngine(
            inspector: FixedFocus(focus: focus),
            keyboard: keyboard,
            secureProbe: FixedSecureInput(active: secureInputActive)
        )
    }

    private func makeRouter(
        pasteboard: FakePasteboard,
        keyboard: CountingKeyboard,
        typer: RecordingTyper,
        focus: AXFocusInfo? = AXFocusInfo(role: "AXTextField", subrole: nil),
        secureInputActive: Bool = false
    ) -> TranscriptionOutputRouter {
        TranscriptionOutputRouter(
            pasteEngine: makeEngine(keyboard: keyboard, focus: focus, secureInputActive: secureInputActive),
            pasteboard: pasteboard,
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 1_000_000,
            textTyper: typer
        )
    }
}

/// The typed path and clipboard history: the real pasteboard (a named one), the real
/// monitor and store, joined the way `AppCoordinator` joins them.
@MainActor
final class TypingFallbackHistoryTests: XCTestCase {
    private var tempDir: URL!
    private var board: NSPasteboard!
    private var store: ClipboardHistoryStore!
    private var monitor: ClipboardMonitor!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-TypingFallbackHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        board = NSPasteboard(name: NSPasteboard.Name("WhisperKeyTypingTests-\(UUID().uuidString)"))
        board.clearContents()
        store = ClipboardHistoryStore(url: tempDir.appendingPathComponent("clipboard-history.json"))
        monitor = ClipboardMonitor.recording(
            into: store,
            pasteboard: SystemClipboardReader(pasteboard: board),
            pollInterval: 3600
        )
        monitor.start()
    }

    override func tearDown() async throws {
        monitor?.stop()
        monitor = nil
        store = nil
        board?.releaseGlobally()
        board = nil
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Nothing reaches the clipboard on the typed path, so nothing but the router can put
    /// the dictation into quick paste. And the file is exactly where the user left it.
    func testATypedTranscriptIsRecordedAndTheFileStaysOnTheClipboard() async throws {
        let file = tempDir.appendingPathComponent("Screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        monitor.poll()
        let changeCountBefore = board.changeCount
        let typer = RecordingTyper()
        let router = TranscriptionOutputRouter(
            pasteEngine: PasteEngine(
                inspector: FixedFocus(focus: AXFocusInfo(role: "AXTextField", subrole: nil)),
                keyboard: CountingKeyboard(),
                secureProbe: FixedSecureInput(active: false)
            ),
            pasteboard: SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 1_000_000,
            clipboardHistory: TranscriptionClipboardHistory(monitor: monitor, store: store),
            textTyper: typer
        )

        let result = await router.deliver(
            text: "dictated",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
        )
        monitor.poll()

        XCTAssertEqual(result.delivery, .typed)
        XCTAssertEqual(typer.typed, ["dictated"])
        XCTAssertEqual(store.entries.first?.text, "dictated")
        XCTAssertEqual(store.entries.first?.origin, .whisperKey)
        XCTAssertEqual(board.changeCount, changeCountBefore, "the clipboard was written")
        let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [file.standardizedFileURL])
        XCTAssertFalse(monitor.isSuspended)
    }

    /// A refused field gets nothing typed, and the clipboard still holds the file, so the
    /// dictation exists nowhere but in quick paste. It is recorded there regardless, as on
    /// the swap, where a refused paste is recorded too.
    func testARefusedFieldTypesNothingButTheTranscriptIsStillRecorded() async throws {
        let file = tempDir.appendingPathComponent("Screenshot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        monitor.poll()
        let changeCountBefore = board.changeCount
        let typer = RecordingTyper()
        let keyboard = CountingKeyboard()
        let router = TranscriptionOutputRouter(
            pasteEngine: PasteEngine(
                inspector: FixedFocus(focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField")),
                keyboard: keyboard,
                secureProbe: FixedSecureInput(active: false)
            ),
            pasteboard: SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 1_000_000,
            clipboardHistory: TranscriptionClipboardHistory(monitor: monitor, store: store),
            textTyper: typer
        )

        let result = await router.deliver(
            text: "dictated",
            settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true),
            secureFieldPolicy: .refuse
        )
        monitor.poll()

        XCTAssertEqual(result.delivery, .typed)
        XCTAssertEqual(result.pasteDecision, .clipboardOnly)
        XCTAssertEqual(typer.typed, [], "typed into a refused field")
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(board.changeCount, changeCountBefore, "the clipboard was written")
        let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [file.standardizedFileURL])
        XCTAssertEqual(store.entries.first?.text, "dictated", "the refused dictation is not in quick paste")
        XCTAssertEqual(store.entries.first?.origin, .whisperKey)
    }
}

/// The real typer, with its events captured instead of posted.
final class CGEventTextTyperTests: XCTestCase {

    /// The event source merges physically held keys; a modifier still down from the
    /// hotkey would turn the text into shortcuts. The factory here hands out events with
    /// ⌘ and ⌥ already set, standing in for that hand.
    func testEveryTypedEventCarriesNoModifierFlags() async {
        let capture = EventCapture()

        await capture.typer().type("Hello, world. A sentence longer than one chunk.")

        XCTAssertFalse(capture.events.isEmpty)
        for event in capture.events {
            XCTAssertEqual(event.flags.rawValue, 0, "event with flags \(event.flags)")
        }
    }

    func testTheKeyDownsCarryTheTextInOrderEachFollowedByItsKeyUp() async {
        let capture = EventCapture()
        let text = String(repeating: "abcdefghij", count: 4) + "xyz"

        await capture.typer().type(text)

        let events = capture.events
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        let downs = events.filter { $0.type == .keyDown }.map(Self.unicodeString)
        let ups = events.filter { $0.type == .keyUp }.map(Self.unicodeString)
        XCTAssertEqual(downs.joined(), text)
        XCTAssertEqual(downs, ups)
        XCTAssertEqual(downs.map(\.utf16.count), [20, 20, 3])
    }

    func testChunksAreCutAtTwentyUTF16Units() {
        XCTAssertEqual(
            TypedText.chunks(of: String(repeating: "a", count: 45)).map(\.utf16.count),
            [20, 20, 5]
        )
    }

    /// A family emoji is eleven UTF-16 units; a cut at twenty units lands in its middle.
    func testAChunkNeverSplitsAnEmoji() {
        let family = "👨‍👩‍👧‍👦"
        let leading = String(repeating: "a", count: 19)

        XCTAssertEqual(TypedText.chunks(of: leading + family + "b"), [leading, family + "b"])
    }

    func testAChunkNeverSplitsASurrogatePair() {
        let leading = String(repeating: "a", count: 19)

        XCTAssertEqual(TypedText.chunks(of: leading + "😀"), [leading, "😀"])
    }

    func testAChunkNeverSplitsADecomposedLetter() {
        let leading = String(repeating: "a", count: 19)
        let decomposed = "e\u{301}"

        let chunks = TypedText.chunks(of: leading + decomposed)

        XCTAssertEqual(chunks.map { Array($0.unicodeScalars) }, [Array(leading.unicodeScalars), Array(decomposed.unicodeScalars)])
    }

    /// One character longer than a chunk goes whole, in a chunk of its own.
    func testACharacterLongerThanAChunkGoesWholeAndAlone() {
        let long = "e" + String(repeating: "\u{301}", count: 25)
        XCTAssertEqual(long.count, 1)

        XCTAssertEqual(TypedText.chunks(of: "ab" + long + "cd"), ["ab", long, "cd"])
    }

    /// At the very start too, with no empty piece before it: an empty piece would post a
    /// key event with no text, which some targets read as the virtual key itself.
    func testATextStartingWithACharacterLongerThanAChunkHasNoEmptyPiece() {
        let long = "e" + String(repeating: "\u{301}", count: 25)

        XCTAssertEqual(TypedText.chunks(of: long + "cd"), [long, "cd"])
    }

    func testEveryKindOfLineBreakBecomesOneSpace() {
        XCTAssertEqual(
            TypedText.replacingLineBreaks("a\nb\r\nc\rd\u{2028}e\u{2029}f"),
            "a b c d e f"
        )
        XCTAssertEqual(TypedText.replacingLineBreaks("no breaks"), "no breaks")
    }

    private static func unicodeString(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}

// MARK: - Fakes

private extension TranscriptionOutputSettings {
    static let autoPasteOnly = TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
}

private struct FixedFocus: AXFocusInspector {
    let focus: AXFocusInfo?
    func currentFocus() -> AXFocusInfo? { focus }
}

private struct FixedSecureInput: SecureInputProbe {
    let active: Bool
    func isSecureInputActive() -> Bool { active }
}

private final class CountingKeyboard: KeyboardSimulator, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.withLock { count } }
    func sendCommandV() { lock.withLock { count += 1 } }
}

private final class RecordingTyper: TextTyper, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    var typed: [String] { lock.withLock { texts } }
    func type(_ text: String) async { lock.withLock { texts.append(text) } }
}

/// A clipboard holding arbitrary items, counting every write and restore.
private final class FakePasteboard: TranscriptionPasteboard, @unchecked Sendable {
    private(set) var items: [[NSPasteboard.PasteboardType: Data]]
    private(set) var writeCallCount = 0
    private(set) var restoreCallCount = 0

    init(items: [[NSPasteboard.PasteboardType: Data]]) {
        self.items = items
    }

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: items)
    }

    func replaceWithString(_ string: String) -> Bool {
        writeCallCount += 1
        items = [[.string: Data(string.utf8)]]
        return true
    }

    func replaceWithPromisedString(_ string: String) -> PasteboardReadSignal? {
        replaceWithString(string) ? PasteboardReadSignal() : nil
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        restoreCallCount += 1
        items = snapshot.items
        return true
    }
}

/// Builds the events a held ⌘⌥ would leave flagged, and keeps what the typer posts.
private final class EventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [CGEvent] = []
    var events: [CGEvent] { lock.withLock { posted } }

    func typer() -> CGEventTextTyper {
        CGEventTextTyper(
            makeEvent: { keyDown in
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                event?.flags = [.maskCommand, .maskAlternate]
                return event
            },
            post: { [self] event in lock.withLock { posted.append(event) } },
            pauseBetweenChunksNanoseconds: 0
        )
    }
}
