import AppKit
import XCTest
@testable import ClipboardHistoryStore
@testable import PasteEngine

/// The `(saveToClipboard: false, autoPaste: true)` swap restores the user's clipboard only
/// after the paste target has read the transcript.
///
/// A fixed 150 ms timer used to stand there. On a loaded Mac the target handled ⌘V after
/// the timer had already put the user's image back, and pasted the image instead of the
/// dictation. The transcript is now a promise, and the restore waits for it to be kept.
final class PasteRestoreAfterReadTests: XCTestCase {

    /// The owner's case: the target reads 300 ms after the keystroke, long after the old
    /// timer would have fired. It still gets the transcript, and the restore comes after.
    func testTheClipboardIsRestoredOnlyAfterTheTargetReadsTheTranscript() async {
        let pasteboard = LateReadingPasteboard(current: "the user's image")
        let readDone = expectation(description: "the target read the clipboard")
        let keyboard = CallbackKeyboard {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
                pasteboard.readAsTheTarget()
                readDone.fulfill()
            }
        }
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            restoreDelayNanoseconds: 10_000_000,
            readTimeoutNanoseconds: 10_000_000_000
        )

        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)
        await fulfillment(of: [readDone], timeout: 10)

        XCTAssertEqual(pasteboard.readsByTheTarget, ["dictated"])
        XCTAssertEqual(pasteboard.events, ["write", "read", "restore"])
        XCTAssertEqual(pasteboard.currentString, "the user's image")
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .paste,
            restoredClipboard: true
        ))
    }

    /// An application may read the clipboard more than once for one paste, so a read is
    /// followed by the short grace before the restore, not by the restore itself.
    func testAReadIsFollowedByTheGraceBeforeTheRestore() async {
        let pasteboard = LateReadingPasteboard(current: "previous")
        let keyboard = CallbackKeyboard { pasteboard.readAsTheTarget() }
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            restoreDelayNanoseconds: 200_000_000,
            readTimeoutNanoseconds: 10_000_000_000
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertGreaterThanOrEqual(elapsed, 200_000_000)
        XCTAssertLessThan(elapsed, 10_000_000_000, "waited for the read timeout after a read")
        XCTAssertEqual(pasteboard.events, ["write", "read", "restore"])
        XCTAssertTrue(result.restoredClipboard)
    }

    /// A target that never reads must not keep the user's clipboard hostage: at the read
    /// timeout the restore goes ahead.
    func testWithNoReadTheClipboardIsRestoredAtTheReadTimeout() async {
        let pasteboard = LateReadingPasteboard(current: "previous")
        let keyboard = CallbackKeyboard {}
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 100_000_000
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertGreaterThanOrEqual(elapsed, 100_000_000, "restored before the read timeout")
        XCTAssertEqual(pasteboard.events, ["write", "restore"])
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(keyboard.callCount, 1)
        XCTAssertTrue(result.restoredClipboard)
    }

    /// No keystroke was sent into a field labelled secure, so nothing is coming to read:
    /// the restore does not wait, neither for a read nor for the grace.
    func testARefusedPasteRestoresWithoutWaiting() async {
        let pasteboard = LateReadingPasteboard(current: "previous")
        let keyboard = CallbackKeyboard {}
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            focus: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField"),
            restoreDelayNanoseconds: 3_000_000_000,
            readTimeoutNanoseconds: 3_000_000_000
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertLessThan(elapsed, 1_500_000_000, "waited although no keystroke was sent")
        XCTAssertEqual(keyboard.callCount, 0)
        XCTAssertEqual(pasteboard.events, ["write", "restore"])
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(result, TranscriptionOutputResult(
            wroteClipboard: true,
            pasteDecision: .clipboardOnly,
            restoredClipboard: true
        ))
    }

    /// Cancelling a delivery that waits for the read still puts the clipboard back, and
    /// does it at once rather than at the read timeout.
    func testCancellingWhileWaitingForTheReadRestoresAtOnce() async {
        let pasteboard = LateReadingPasteboard(current: "previous")
        let keyboard = CallbackKeyboard {}
        let router = makeRouter(
            pasteboard: pasteboard,
            keyboard: keyboard,
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 30_000_000_000
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let task = Task { await router.deliver(text: "dictated", settings: .autoPasteOnly) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertLessThan(elapsed, 15_000_000_000, "the cancellation did not end the wait")
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertTrue(result.restoredClipboard)
    }

    // MARK: - A real pasteboard

    /// The system pasteboard keeps the promise: a read gets the transcript, the origin
    /// marker is on the item from the start, and the read fires the signal.
    func testARealPasteboardKeepsThePromiseAndFiresTheSignal() async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("WhisperKeyPromiseTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let pasteboard = SystemTranscriptionPasteboard(pasteboard: board)

        let signal = try XCTUnwrap(pasteboard.replaceWithPromisedString("a dictated sentence"))

        XCTAssertFalse(signal.hasFired, "fired before anything read the clipboard")
        let markerType = NSPasteboard.PasteboardType(ClipboardOriginMarker.pasteboardType)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.pasteboardItems?.first?.types.contains(markerType), true)
        XCTAssertEqual(board.string(forType: .string), "a dictated sentence")
        let fired = await signal.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(fired, "the read did not fire the signal")
        XCTAssertEqual(board.string(forType: .string), "a dictated sentence", "a second read lost the text")
    }

    /// The real pasteboard through the whole swap: the target reads during the paste,
    /// gets the transcript, and the user's own copy is back afterwards, unmarked.
    func testARealPasteboardSwapHandsTheTranscriptToTheTargetAndRestores() async {
        let board = NSPasteboard(name: NSPasteboard.Name("WhisperKeyPromiseTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("what the user copied", forType: .string)
        let seen = LockedValue<String?>(nil)
        let keyboard = CallbackKeyboard { seen.set(board.string(forType: .string)) }
        let router = TranscriptionOutputRouter(
            pasteEngine: PasteEngine(
                inspector: StubFocus(focus: AXFocusInfo(role: "AXTextField", subrole: nil)),
                keyboard: keyboard,
                secureProbe: StubSecureInputProbe(active: false)
            ),
            pasteboard: SystemTranscriptionPasteboard(pasteboard: board),
            restoreDelayNanoseconds: 0,
            readTimeoutNanoseconds: 10_000_000_000
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let result = await router.deliver(text: "dictated", settings: .autoPasteOnly)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertEqual(seen.get(), "dictated")
        XCTAssertLessThan(elapsed, 5_000_000_000, "the read during the paste did not end the wait")
        XCTAssertTrue(result.restoredClipboard)
        XCTAssertEqual(board.string(forType: .string), "what the user copied")
        let markerType = NSPasteboard.PasteboardType(ClipboardOriginMarker.pasteboardType)
        XCTAssertEqual(board.pasteboardItems?.first?.types.contains(markerType), false)
    }

    // MARK: - Helpers

    private func makeRouter(
        pasteboard: LateReadingPasteboard,
        keyboard: CallbackKeyboard,
        focus: AXFocusInfo? = AXFocusInfo(role: "AXTextField", subrole: nil),
        restoreDelayNanoseconds: UInt64,
        readTimeoutNanoseconds: UInt64
    ) -> TranscriptionOutputRouter {
        TranscriptionOutputRouter(
            pasteEngine: PasteEngine(
                inspector: StubFocus(focus: focus),
                keyboard: keyboard,
                secureProbe: StubSecureInputProbe(active: false)
            ),
            pasteboard: pasteboard,
            restoreDelayNanoseconds: restoreDelayNanoseconds,
            readTimeoutNanoseconds: readTimeoutNanoseconds
        )
    }
}

/// The signal on its own: every order in which the read and the wait can meet.
final class PasteboardReadSignalTests: XCTestCase {

    func testAReadBeforeTheWaitIsSeenAtOnce() async {
        let signal = PasteboardReadSignal()
        signal.fire()

        let started = DispatchTime.now().uptimeNanoseconds
        let fired = await signal.wait(timeoutNanoseconds: 10_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertTrue(fired)
        XCTAssertTrue(signal.hasFired)
        XCTAssertLessThan(elapsed, 5_000_000_000)
    }

    func testAReadDuringTheWaitEndsIt() async {
        let signal = PasteboardReadSignal()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { signal.fire() }

        let started = DispatchTime.now().uptimeNanoseconds
        let fired = await signal.wait(timeoutNanoseconds: 10_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertTrue(fired)
        XCTAssertLessThan(elapsed, 5_000_000_000, "ended by the timeout, not by the read")
    }

    func testNoReadEndsTheWaitAtTheTimeout() async {
        let signal = PasteboardReadSignal()

        let started = DispatchTime.now().uptimeNanoseconds
        let fired = await signal.wait(timeoutNanoseconds: 50_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertFalse(fired)
        XCTAssertFalse(signal.hasFired)
        XCTAssertGreaterThanOrEqual(elapsed, 50_000_000)
    }

    /// A read after a timed-out wait still counts for the next wait.
    func testAReadAfterATimeoutIsSeenByTheNextWait() async {
        let signal = PasteboardReadSignal()
        let first = await signal.wait(timeoutNanoseconds: 10_000_000)
        signal.fire()
        let second = await signal.wait(timeoutNanoseconds: 10_000_000_000)

        XCTAssertFalse(first)
        XCTAssertTrue(second)
    }

    func testFiringTwiceIsHarmless() async {
        let signal = PasteboardReadSignal()
        signal.fire()
        signal.fire()

        let fired = await signal.wait(timeoutNanoseconds: 10_000_000_000)

        XCTAssertTrue(fired)
    }

    func testOneReadWakesEveryWaiter() async {
        let signal = PasteboardReadSignal()
        async let first = signal.wait(timeoutNanoseconds: 10_000_000_000)
        async let second = signal.wait(timeoutNanoseconds: 10_000_000_000)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { signal.fire() }

        let results = await [first, second]

        XCTAssertEqual(results, [true, true])
    }

    func testCancellationEndsTheWaitWithNoRead() async {
        let signal = PasteboardReadSignal()

        let started = DispatchTime.now().uptimeNanoseconds
        let task = Task { await signal.wait(timeoutNanoseconds: 30_000_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let fired = await task.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertFalse(fired)
        XCTAssertLessThan(elapsed, 15_000_000_000, "the cancellation did not end the wait")
        // The continuation was resumed once and dropped: a read now resumes nothing.
        signal.fire()
    }

    func testAWaitInAnAlreadyCancelledTaskReturnsAtOnce() async {
        let signal = PasteboardReadSignal()

        let started = DispatchTime.now().uptimeNanoseconds
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await signal.wait(timeoutNanoseconds: 30_000_000_000)
        }
        let fired = await task.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertFalse(fired)
        XCTAssertLessThan(elapsed, 15_000_000_000)
    }
}

private extension TranscriptionOutputSettings {
    static let autoPasteOnly = TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
}

private struct StubFocus: AXFocusInspector {
    let focus: AXFocusInfo?
    func currentFocus() -> AXFocusInfo? { focus }
}

private struct StubSecureInputProbe: SecureInputProbe {
    let active: Bool
    func isSecureInputActive() -> Bool { active }
}

/// Stands where ⌘V is posted; `onPaste` is what the target application does about it.
private final class CallbackKeyboard: KeyboardSimulator, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let onPaste: () -> Void

    init(onPaste: @escaping () -> Void) {
        self.onPaste = onPaste
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func sendCommandV() {
        lock.lock()
        calls += 1
        lock.unlock()
        onPaste()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// A clipboard read only when the test says so, the way a busy target application reads
/// it some time after the keystroke. A promised write hands back a signal that the read
/// fires, as the system pasteboard's data provider does.
private final class LateReadingPasteboard: TranscriptionPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?
    private var signal: PasteboardReadSignal?
    private var log: [String] = []
    private var reads: [String?] = []

    init(current: String?) {
        self.current = current
    }

    var currentString: String? { locked { current } }
    var events: [String] { locked { log } }
    var readsByTheTarget: [String?] { locked { reads } }

    func readAsTheTarget() {
        let signal: PasteboardReadSignal? = locked {
            log.append("read")
            reads.append(current)
            return self.signal
        }
        signal?.fire()
    }

    func snapshot() -> PasteboardSnapshot {
        locked {
            guard let current else { return PasteboardSnapshot(items: []) }
            return PasteboardSnapshot(items: [[.string: Data(current.utf8)]])
        }
    }

    func replaceWithString(_ string: String) -> Bool {
        locked {
            log.append("write")
            current = string
            signal = nil
        }
        return true
    }

    func replaceWithPromisedString(_ string: String) -> PasteboardReadSignal? {
        let signal = PasteboardReadSignal()
        locked {
            log.append("write")
            current = string
            self.signal = signal
        }
        return signal
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        locked {
            log.append("restore")
            current = snapshot.items.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
            signal = nil
        }
        return true
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
