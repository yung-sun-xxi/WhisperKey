import XCTest
@testable import ClipboardHistoryStore

/// A pasteboard that only exists in memory. No test in this file touches the live clipboard.
///
/// `write` models what `NSPasteboard` actually does: `clearContents` bumps the change
/// counter, so a swap-and-restore moves it by two.
private final class FakePasteboard: ClipboardReading {
    private(set) var changeCount = 0
    private var content = ClipboardContent(string: nil, types: [])
    private(set) var readCount = 0

    func write(string: String?, types: Set<String> = []) {
        changeCount += 1
        var allTypes = types
        if string != nil { allTypes.insert("public.utf8-plain-text") }
        content = ClipboardContent(string: string, types: allTypes)
    }

    /// A non-string item — an image, say.
    func writeNonString() {
        changeCount += 1
        content = ClipboardContent(string: nil, types: ["public.tiff"])
    }

    func read() -> ClipboardContent {
        readCount += 1
        return content
    }
}

private final class CaptureSink {
    private(set) var captures: [(text: String, origin: ClipboardEntryOrigin, isConcealed: Bool)] = []
    var texts: [String] { captures.map(\.text) }
    var origins: [ClipboardEntryOrigin] { captures.map(\.origin) }
    var concealment: [Bool] { captures.map(\.isConcealed) }

    func record(_ text: String, _ origin: ClipboardEntryOrigin, _ isConcealed: Bool) {
        captures.append((text, origin, isConcealed))
    }
}

final class ClipboardMonitorTests: XCTestCase {

    private var pasteboard: FakePasteboard!
    private var sink: CaptureSink!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        sink = CaptureSink()
        let sink = self.sink!
        monitor = ClipboardMonitor(pasteboard: pasteboard) { text, origin, isConcealed in
            sink.record(text, origin, isConcealed)
        }
    }

    override func tearDown() {
        monitor?.stop()
        monitor = nil
        super.tearDown()
    }

    // MARK: - The counter

    func testAChangeProducesOneCapture() {
        pasteboard.write(string: "hello")
        monitor.poll()

        XCTAssertEqual(sink.texts, ["hello"])
    }

    func testAnUnchangedCounterProducesNothing() {
        pasteboard.write(string: "hello")
        monitor.poll()
        monitor.poll()
        monitor.poll()

        XCTAssertEqual(sink.texts, ["hello"])
    }

    func testEachDistinctCopyProducesItsOwnCapture() {
        for text in ["one", "two", "three"] {
            pasteboard.write(string: text)
            monitor.poll()
        }

        XCTAssertEqual(sink.texts, ["one", "two", "three"])
    }

    func testWhatWasAlreadyOnThePasteboardAtStartIsNotCaptured() {
        pasteboard.write(string: "from before launch")
        monitor.start()
        monitor.poll()

        XCTAssertEqual(sink.texts, [])
    }

    // MARK: - What is skipped

    /// Replaces `testConcealedItemIsNotCaptured`, which encoded the rule this change
    /// reverses. A password copied from a password manager is now recorded like anything
    /// else, so that the popup can reach it — what protects it is that it is never
    /// written to disk, which is asserted against the file itself in
    /// `ClipboardHistoryStoreTests` and in `testAConcealedCopyNeverReachesTheHistoryFile`
    /// below, not here.
    func testConcealedItemIsCapturedAndFlaggedConcealed() {
        pasteboard.write(string: "hunter2", types: [ClipboardMonitor.concealedTypeIdentifier])
        monitor.poll()

        XCTAssertEqual(sink.texts, ["hunter2"])
        XCTAssertEqual(sink.concealment, [true])
    }

    func testAnOrdinaryItemIsNotFlaggedConcealed() {
        pasteboard.write(string: "ordinary")
        monitor.poll()

        XCTAssertEqual(sink.concealment, [false])
    }

    func testAConcealedCopyAndTheOrdinaryCopyAfterItAreBothCaptured() {
        pasteboard.write(string: "hunter2", types: [ClipboardMonitor.concealedTypeIdentifier])
        monitor.poll()
        pasteboard.write(string: "ordinary")
        monitor.poll()

        XCTAssertEqual(sink.texts, ["hunter2", "ordinary"])
        XCTAssertEqual(sink.concealment, [true, false])
    }

    func testNonStringContentIsNotCaptured() {
        pasteboard.writeNonString()
        monitor.poll()

        XCTAssertEqual(sink.texts, [])
    }

    // MARK: - Origin

    func testAnItemCarryingTheOriginMarkerIsAttributedToWhisperKey() {
        pasteboard.write(string: "dictated", types: [ClipboardOriginMarker.pasteboardType])
        monitor.poll()

        XCTAssertEqual(sink.captures.map(\.origin), [.whisperKey])
    }

    func testAnUnmarkedItemIsAttributedToAnotherApplication() {
        pasteboard.write(string: "hand copied")
        monitor.poll()

        XCTAssertEqual(sink.captures.map(\.origin), [.otherApplication])
    }

    // MARK: - Suspend / resume

    func testNothingIsCapturedWhileSuspended() {
        monitor.suspend()
        pasteboard.write(string: "the popup's own write")
        monitor.poll()

        XCTAssertEqual(sink.texts, [])
    }

    func testSuspensionDoesNotEvenReadThePasteboard() {
        monitor.suspend()
        pasteboard.write(string: "the popup's own write")
        monitor.poll()

        XCTAssertEqual(pasteboard.readCount, 0)
    }

    /// The subtle one. A swap-and-restore moves the counter by two, because each write
    /// clears the pasteboard first. A monitor that resumes against a stale baseline sees
    /// a counter it does not recognise and records the *restored* content as a fresh copy.
    func testNothingIsCapturedOnTheFirstPollAfterResumeFollowingASwapAndRestore() {
        pasteboard.write(string: "what the user copied")
        monitor.poll()
        XCTAssertEqual(sink.texts, ["what the user copied"])

        monitor.suspend()
        pasteboard.write(string: "the text being pasted")   // swap
        pasteboard.write(string: "what the user copied")    // restore
        monitor.resume()
        monitor.poll()

        XCTAssertEqual(sink.texts, ["what the user copied"], "the restored clipboard must not be recorded again")
    }

    /// Re-baselining must not deafen the monitor: the next real copy still lands.
    func testACopyAfterResumeIsStillCaptured() {
        monitor.suspend()
        pasteboard.write(string: "swap")
        pasteboard.write(string: "restore")
        monitor.resume()
        monitor.poll()

        pasteboard.write(string: "a genuinely new copy")
        monitor.poll()

        XCTAssertEqual(sink.texts, ["a genuinely new copy"])
    }

    /// The restore is not always to the same text — the pasteboard may have been empty.
    /// De-duplication cannot cover this case, so the re-baseline has to.
    func testResumeAfterASwapOverAnEmptyPasteboardCapturesNothing() {
        monitor.suspend()
        pasteboard.write(string: "the text being pasted")
        pasteboard.write(string: nil)
        monitor.resume()
        monitor.poll()

        XCTAssertEqual(sink.texts, [])
    }

    func testStopAndStartAreIdempotent() {
        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    // MARK: - Monitor into store

    func testMonitorFeedingTheStoreProducesTheHistoryThePopupShows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-MonitorStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardHistoryStore(url: dir.appendingPathComponent("clipboard-history.json"), maxEntries: 3)
        let board = FakePasteboard()
        // The same join the app uses, so breaking it breaks a test rather than only the app.
        let monitor = ClipboardMonitor.recording(into: store, pasteboard: board)
        defer { monitor.stop() }

        board.write(string: "one"); monitor.poll()
        board.write(string: "   "); monitor.poll()                                               // whitespace, dropped
        board.write(string: "one"); monitor.poll()                                               // repeat, dropped
        board.write(string: "hunter2", types: [ClipboardMonitor.concealedTypeIdentifier]); monitor.poll()
        board.write(string: "two", types: [ClipboardOriginMarker.pasteboardType]); monitor.poll()
        board.writeNonString(); monitor.poll()
        board.write(string: "three"); monitor.poll()

        // "hunter2" is in the list, and it took a slot from "one" like any other entry.
        XCTAssertEqual(store.entries.map(\.text), ["three", "two", "hunter2"])
        XCTAssertEqual(store.entries.map(\.origin), [.otherApplication, .whisperKey, .otherApplication])
        XCTAssertEqual(store.entries.map(\.isConcealed), [false, false, true])
    }

    /// The whole point of the change, proved where it matters: through the real monitor,
    /// the real store and the real file. Passing `false` for concealment anywhere along
    /// this chain puts the password on disk and fails here.
    func testAConcealedCopyNeverReachesTheHistoryFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-MonitorConcealed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("clipboard-history.json")
        let store = ClipboardHistoryStore(url: url)
        let board = FakePasteboard()
        let monitor = ClipboardMonitor.recording(into: store, pasteboard: board)
        defer { monitor.stop() }

        board.write(string: "an ordinary copy"); monitor.poll()
        board.write(string: "hunter2", types: [ClipboardMonitor.concealedTypeIdentifier]); monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["hunter2", "an ordinary copy"])

        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be in the file:\n\(onDisk)")
        XCTAssertTrue(onDisk.contains("an ordinary copy"))
    }

    func testRecordingFactoryPutsWhatItCapturesIntoTheStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-MonitorFactory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardHistoryStore(url: dir.appendingPathComponent("clipboard-history.json"))
        let board = FakePasteboard()
        let monitor = ClipboardMonitor.recording(into: store, pasteboard: board)
        defer { monitor.stop() }

        board.write(string: "copied")
        monitor.poll()

        XCTAssertEqual(store.entries.map(\.text), ["copied"])
    }
}
