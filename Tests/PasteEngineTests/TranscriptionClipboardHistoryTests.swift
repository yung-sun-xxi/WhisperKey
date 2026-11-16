import AppKit
import XCTest
@testable import ClipboardHistoryStore
@testable import PasteEngine

/// The transcription output path and clipboard history together (#211): the router, the
/// real monitor and the real store, joined the way `AppCoordinator` joins them.
///
/// Like `ClipboardOriginMarkerTests`, these run against a *named* `NSPasteboard` created
/// for the test, never `NSPasteboard.general`, and against a store file in a temporary
/// directory.
///
/// The monitor's timer never fires here (its interval is an hour); every poll is called
/// by hand, at the moment the test is about. The poll that matters most is the one that
/// lands *between* the router's write and its restore: the keyboard spy stands exactly
/// there, so it is the one that makes it.
@MainActor
final class TranscriptionClipboardHistoryTests: XCTestCase {

    private var tempDir: URL!
    private var board: NSPasteboard!
    private var store: ClipboardHistoryStore!
    private var monitor: ClipboardMonitor!
    private var keyboard: PollingKeyboard!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-TranscriptionClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        board = NSPasteboard(name: NSPasteboard.Name("WhisperKeyHistoryTests-\(UUID().uuidString)"))
        board.clearContents()
        store = ClipboardHistoryStore(url: tempDir.appendingPathComponent("clipboard-history.json"))
        monitor = ClipboardMonitor.recording(
            into: store,
            pasteboard: SystemClipboardReader(pasteboard: board),
            pollInterval: 3600
        )
        monitor.start()
        keyboard = PollingKeyboard()
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

    // MARK: - 1. The swap-and-restore never reaches the history

    /// The poll lands between the write and the restore, and another one after the
    /// restore. Unsuspended, the second records the restored text as a fresh hand copy.
    func testARestoreAfterAutoPasteIsNotRecordedAsAFreshCopy() async {
        copyByHand("copied by hand")
        monitor.poll()
        keyboard.onPaste = { [monitor] in monitor?.poll() }

        await makeRouter().deliver(text: "first dictation", settings: .autoPasteOnly)
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["first dictation", "copied by hand"])
        XCTAssertEqual(store.entries.map(\.origin), [.whisperKey, .otherApplication])
    }

    /// The scenario from the ticket's "Done when": copy X, dictate three times, and the
    /// list is the three dictations and one X, newest on top — whichever side of the
    /// poll race each dictation falls on.
    func testThreeDictationsAfterAHandCopyLeaveThreeDictationsAndOneCopy() async {
        copyByHand("X")
        monitor.poll()
        let router = makeRouter()

        keyboard.onPaste = { [monitor] in monitor?.poll() }
        await router.deliver(text: "one", settings: .autoPasteOnly)
        monitor.poll()

        keyboard.onPaste = nil
        await router.deliver(text: "two", settings: .autoPasteOnly)
        monitor.poll()

        keyboard.onPaste = { [monitor] in monitor?.poll() }
        await router.deliver(text: "three", settings: .autoPasteOnly)
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["three", "two", "one", "X"])
        XCTAssertEqual(board.string(forType: .string), "X")
    }

    /// The monitor listens again after the swap, against the counter as it stands then.
    func testAHandCopyAfterAnAutoPasteIsStillRecorded() async {
        await makeRouter().deliver(text: "dictated", settings: .autoPasteOnly)
        XCTAssertFalse(monitor.isSuspended)

        copyByHand("copied afterwards")
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["copied afterwards", "dictated"])
    }

    /// `resume()` re-baselines, so a copy the monitor had not polled yet when the swap
    /// started would vanish with it. It is taken before the monitor goes quiet.
    func testACopyNotYetPolledWhenTheSwapStartsIsNotLost() async {
        copyByHand("copied a moment ago")

        await makeRouter().deliver(text: "dictated", settings: .autoPasteOnly)
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["dictated", "copied a moment ago"])
        XCTAssertEqual(store.entries.map(\.origin), [.whisperKey, .otherApplication])
    }

    /// Cancelled right after the snapshot: nothing was written, and the monitor must not
    /// stay silent for the rest of the app's life.
    func testACancellationBeforeTheWriteStillResumesTheMonitor() async {
        copyByHand("copied by hand")
        monitor.poll()
        let pasteboard = CancellingPasteboard(board: board, cancelAt: .snapshot)

        let result = await makeRouter(pasteboard: pasteboard).deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertFalse(result.wroteClipboard)
        XCTAssertFalse(monitor.isSuspended)
        copyByHand("copied afterwards")
        monitor.poll()
        XCTAssertEqual(store.entries.map(\.text), ["copied afterwards", "copied by hand"])
    }

    /// Cancelled right after the write: the clipboard is restored, the monitor resumed
    /// and re-baselined — the restore is not a copy — and a transcript that was never
    /// pasted is not offered in the list.
    func testACancellationAfterTheWriteRestoresResumesAndRecordsNothing() async {
        copyByHand("copied by hand")
        monitor.poll()
        let handCopyID = store.entries.first?.id
        let pasteboard = CancellingPasteboard(board: board, cancelAt: .write)

        let result = await makeRouter(pasteboard: pasteboard).deliver(text: "dictated", settings: .autoPasteOnly)
        monitor.poll()

        XCTAssertTrue(result.restoredClipboard)
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertFalse(monitor.isSuspended)
        XCTAssertEqual(store.entries.map(\.text), ["copied by hand"])
        // A recorded restore would be the same text again, which the store turns into a
        // new entry on top: the id is what shows that nothing was recorded at all.
        XCTAssertEqual(store.entries.map(\.id), [handCopyID])
        copyByHand("copied afterwards")
        monitor.poll()
        XCTAssertEqual(store.entries.map(\.text), ["copied afterwards", "copied by hand"])
    }

    /// A monitor someone else suspended is theirs to resume: the router leaves it as it
    /// found it.
    func testAMonitorSuspendedByTheCallerStaysSuspended() async {
        monitor.suspend()

        await makeRouter().deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertTrue(monitor.isSuspended)
    }

    // MARK: - 2. The transcript is recorded explicitly, exactly once

    /// With no poll between the write and the restore the monitor never sees the
    /// transcript at all. It is in the list anyway, because the router put it there.
    func testAutoPasteRecordsTheTranscriptWithoutAnyPoll() async {
        await makeRouter().deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertEqual(store.entries.map(\.text), ["dictated"])
        XCTAssertEqual(store.entries.map(\.origin), [.whisperKey])
    }

    /// Clipboard kept and auto-paste: recorded by the router before any poll, and the
    /// monitor's later sight of the same marked write does not make a second entry.
    func testATranscriptKeptOnTheClipboardAndPastedLandsExactlyOnce() async {
        copyByHand("copied by hand")
        monitor.poll()

        await makeRouter().deliver(
            text: "dictated",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true)
        )
        XCTAssertEqual(store.entries.map(\.text), ["dictated", "copied by hand"])

        monitor.poll()
        XCTAssertEqual(store.entries.map(\.text), ["dictated", "copied by hand"])
        XCTAssertEqual(store.entries.map(\.origin), [.whisperKey, .otherApplication])
    }

    func testATranscriptOnlyKeptOnTheClipboardLandsExactlyOnce() async {
        await makeRouter().deliver(
            text: "dictated",
            settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: false)
        )
        XCTAssertEqual(store.entries.map(\.text), ["dictated"])

        monitor.poll()
        XCTAssertEqual(store.entries.map(\.text), ["dictated"])
        XCTAssertEqual(store.entries.map(\.origin), [.whisperKey])
    }

    /// The monitor runs exactly while quick paste is on (`QuickPasteActivation`). Off
    /// means off: nothing is recorded, not the transcript and not a pending hand copy.
    func testNothingIsRecordedWhileTheMonitorIsNotRunning() async {
        monitor.stop()
        copyByHand("copied while the feature is off")
        let router = makeRouter()

        await router.deliver(text: "one", settings: .autoPasteOnly)
        await router.deliver(text: "two", settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: true))
        await router.deliver(text: "three", settings: TranscriptionOutputSettings(saveToClipboard: true, autoPaste: false))

        XCTAssertTrue(store.entries.isEmpty, "recorded \(store.entries.map(\.text))")
    }

    func testAFailedClipboardWriteRecordsNothing() async {
        let pasteboard = CancellingPasteboard(board: board, cancelAt: nil, writeSucceeds: false)

        let result = await makeRouter(pasteboard: pasteboard).deliver(text: "dictated", settings: .autoPasteOnly)

        XCTAssertFalse(result.wroteClipboard)
        XCTAssertFalse(monitor.isSuspended)
        XCTAssertTrue(store.entries.isEmpty, "recorded \(store.entries.map(\.text))")
    }

    // MARK: - The quick-paste shape: a router built without the history

    /// Coverage, not regression proof: this passed before #211 too. The popup builds
    /// `TranscriptionOutputRouter()` with no history and suspends the monitor itself.
    /// What it pastes is an entry already in the list; it must not come back as a
    /// dictation, and the router must not touch the monitor.
    func testARouterWithoutTheHistoryRecordsNothingAndLeavesTheMonitorAlone() async {
        copyByHand("copied by hand")
        monitor.poll()
        let router = TranscriptionOutputRouter(
            pasteEngine: makeEngine(),
            pasteboard: SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0
        )

        monitor.suspend()
        keyboard.onPaste = { [monitor] in XCTAssertEqual(monitor?.isSuspended, true) }
        await router.deliver(text: "an older entry", settings: .autoPasteOnly, secureFieldPolicy: .allow)
        XCTAssertTrue(monitor.isSuspended)
        monitor.resume()
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["copied by hand"])
        XCTAssertEqual(keyboard.callCount, 1)
    }

    // MARK: - Helpers

    private func copyByHand(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func makeEngine() -> PasteEngine {
        PasteEngine(
            inspector: FocusedTextField(),
            keyboard: keyboard,
            secureProbe: NoSecureInput()
        )
    }

    private func makeRouter(pasteboard: TranscriptionPasteboard? = nil) -> TranscriptionOutputRouter {
        TranscriptionOutputRouter(
            pasteEngine: makeEngine(),
            pasteboard: pasteboard ?? SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0,
            clipboardHistory: TranscriptionClipboardHistory(monitor: monitor, store: store)
        )
    }
}

private extension TranscriptionOutputSettings {
    static let autoPasteOnly = TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
}

private struct FocusedTextField: AXFocusInspector {
    func currentFocus() -> AXFocusInfo? { AXFocusInfo(role: "AXTextField", subrole: nil) }
}

private struct NoSecureInput: SecureInputProbe {
    func isSecureInputActive() -> Bool { false }
}

/// Stands where ⌘V is synthesised: after the router's write, before its restore. Whatever
/// `onPaste` does happens on the main thread, where the monitor's timer would fire.
private final class PollingKeyboard: KeyboardSimulator, @unchecked Sendable {
    private(set) var callCount = 0
    var onPaste: (() -> Void)?

    func sendCommandV() {
        callCount += 1
        guard let onPaste else { return }
        if Thread.isMainThread {
            onPaste()
        } else {
            DispatchQueue.main.sync(execute: onPaste)
        }
    }
}

/// The real pasteboard path, with a cancellation of the delivering task injected at a
/// chosen step — the only way to reach the router's cancellation exits on purpose.
private struct CancellingPasteboard: TranscriptionPasteboard {
    enum Step { case snapshot, write }

    private let base: SystemTranscriptionPasteboard
    private let cancelAt: Step?
    private let writeSucceeds: Bool

    init(board: NSPasteboard, cancelAt: Step?, writeSucceeds: Bool = true) {
        self.base = SystemTranscriptionPasteboard(pasteboard: board)
        self.cancelAt = cancelAt
        self.writeSucceeds = writeSucceeds
    }

    func snapshot() -> PasteboardSnapshot {
        let snapshot = base.snapshot()
        if cancelAt == .snapshot { withUnsafeCurrentTask { $0?.cancel() } }
        return snapshot
    }

    func replaceWithString(_ string: String) -> Bool {
        guard writeSucceeds else { return false }
        let wrote = base.replaceWithString(string)
        if cancelAt == .write { withUnsafeCurrentTask { $0?.cancel() } }
        return wrote
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        base.restore(snapshot)
    }
}
