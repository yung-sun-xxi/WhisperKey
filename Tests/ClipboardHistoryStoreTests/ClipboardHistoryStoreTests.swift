import XCTest
@testable import ClipboardHistoryStore

final class ClipboardHistoryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-ClipboardHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeURL() -> URL {
        tempDir.appendingPathComponent("clipboard-history.json")
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Ordering

    func testDistinctTextsAreStoredNewestFirst() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "one", origin: .otherApplication, now: date(1))
        store.record(text: "two", origin: .otherApplication, now: date(2))
        store.record(text: "three", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["three", "two", "one"])
    }

    // MARK: - De-duplication

    func testSameTextTwiceInARowProducesOneEntry() {
        let store = ClipboardHistoryStore(url: makeURL())
        XCTAssertNotNil(store.record(text: "same", origin: .otherApplication, now: date(1)))
        XCTAssertNil(store.record(text: "same", origin: .otherApplication, now: date(2)))

        XCTAssertEqual(store.entries.map(\.text), ["same"])
    }

    func testTextRepeatedAfterAnotherEntryIsStoredAgain() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "a", origin: .otherApplication, now: date(1))
        store.record(text: "b", origin: .otherApplication, now: date(2))
        store.record(text: "a", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["a", "b", "a"])
    }

    func testDeduplicationComparesTextNotOrigin() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "same", origin: .whisperKey, now: date(1))
        XCTAssertNil(store.record(text: "same", origin: .otherApplication, now: date(2)))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.origin, .whisperKey)
    }

    // MARK: - Whitespace

    func testWhitespaceOnlyTextIsNotRecorded() {
        let store = ClipboardHistoryStore(url: makeURL())
        XCTAssertNil(store.record(text: "   ", origin: .otherApplication, now: date(1)))
        XCTAssertNil(store.record(text: "\n\n", origin: .otherApplication, now: date(2)))
        XCTAssertNil(store.record(text: "\t \u{00A0}", origin: .otherApplication, now: date(3)))
        XCTAssertNil(store.record(text: "", origin: .otherApplication, now: date(4)))

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTextWithSurroundingWhitespaceIsRecordedVerbatim() {
        let store = ClipboardHistoryStore(url: makeURL())
        let entry = store.record(text: "  hello  ", origin: .otherApplication, now: date(1))

        XCTAssertEqual(entry?.text, "  hello  ")
        XCTAssertEqual(store.entries.map(\.text), ["  hello  "])
    }

    // MARK: - Cap

    func testEntriesBeyondTheCapAreDroppedOldestFirst() {
        let store = ClipboardHistoryStore(url: makeURL(), maxEntries: 3)
        for i in 1...5 {
            store.record(text: "entry-\(i)", origin: .otherApplication, now: date(TimeInterval(i)))
        }

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.text), ["entry-5", "entry-4", "entry-3"])
    }

    func testZeroCapRejectsEverything() {
        let store = ClipboardHistoryStore(url: makeURL(), maxEntries: 0)
        XCTAssertNil(store.record(text: "anything", origin: .otherApplication, now: date(1)))
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Persistence

    func testEntriesAndOriginSurviveAPersistenceRoundTrip() {
        let url = makeURL()
        let first = ClipboardHistoryStore(url: url)
        first.record(text: "typed by hand", origin: .otherApplication, now: date(1))
        first.record(text: "dictated", origin: .whisperKey, now: date(2))

        let reloaded = ClipboardHistoryStore(url: url)
        XCTAssertEqual(reloaded.entries.map(\.text), ["dictated", "typed by hand"])
        XCTAssertEqual(reloaded.entries.map(\.origin), [.whisperKey, .otherApplication])
        XCTAssertEqual(reloaded.entries.map(\.capturedAt), [date(2), date(1)])
        XCTAssertEqual(reloaded.entries.map(\.id), first.entries.map(\.id))
    }

    func testClearEmptiesTheStoreOnDisk() {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "secret", origin: .otherApplication, now: date(1))
        store.clear()

        XCTAssertTrue(ClipboardHistoryStore(url: url).entries.isEmpty)
    }

    /// A file written before the origin field existed must still load.
    func testStoreFileWrittenBeforeOriginExistedStillLoads() throws {
        let url = makeURL()
        let legacy = """
        [
          {
            "id" : "9F1B3C4D-0000-4000-8000-00000000ABCD",
            "text" : "copied last week",
            "capturedAt" : "1970-01-01T00:00:05Z"
          }
        ]
        """
        try Data(legacy.utf8).write(to: url)

        let store = ClipboardHistoryStore(url: url)
        XCTAssertEqual(store.entries.map(\.text), ["copied last week"])
        XCTAssertEqual(store.entries.first?.origin, .otherApplication)
        XCTAssertEqual(store.entries.first?.capturedAt, date(5))
    }

    // MARK: - Concealed entries

    /// The central assertion of #91, and the only one that proves anything about the
    /// disk: the file is read back as raw bytes and the password is not in it.
    ///
    /// Regression proof. An in-memory flag says nothing about what was written; this is
    /// what fails if the persistence filter is removed or inverted.
    func testAConcealedEntryIsInTheListButNotInTheFile() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "an ordinary copy", origin: .otherApplication, now: date(1))
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(2))

        XCTAssertEqual(store.entries.map(\.text), ["hunter2", "an ordinary copy"])

        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertTrue(onDisk.contains("an ordinary copy"))
    }

    /// Lowering the cap rewrites the file, and that write is as capable of leaking a
    /// concealed entry as any other. `setMaxEntries` is not called on the clipboard store
    /// from the app today, but the entry-count setting is one obvious wire away from it,
    /// and without this test that wiring would put passwords on disk silently.
    func testLoweringTheCapDoesNotWriteConcealedEntriesToTheFile() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url, maxEntries: 5)
        store.record(text: "oldest", origin: .otherApplication, now: date(1))
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(2))
        store.record(text: "newest", origin: .otherApplication, now: date(3))

        store.setMaxEntries(2)

        XCTAssertEqual(store.entries.map(\.text), ["newest", "hunter2"])
        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertTrue(onDisk.contains("newest"))
    }

    /// Coverage for the round trip the user actually experiences: quit, relaunch, the
    /// password is gone and everything else is still there.
    func testARestartDropsConcealedEntriesAndKeepsTheRest() {
        let url = makeURL()
        let first = ClipboardHistoryStore(url: url)
        first.record(text: "keep me", origin: .otherApplication, now: date(1))
        first.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(2))
        first.record(text: "keep me too", origin: .whisperKey, now: date(3))

        let reloaded = ClipboardHistoryStore(url: url)
        XCTAssertEqual(reloaded.entries.map(\.text), ["keep me too", "keep me"])
        XCTAssertEqual(reloaded.entries.map(\.isConcealed), [false, false])
    }

    /// A concealed entry that was never written must not be re-written by a *later*
    /// ordinary copy either. The filter is on every write, not only on the one that
    /// records the password.
    func testALaterOrdinaryCopyDoesNotDragTheConcealedEntryOntoDisk() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(1))
        store.record(text: "afterwards", origin: .otherApplication, now: date(2))
        store.setMaxEntries(5)

        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertTrue(onDisk.contains("afterwards"))
    }

    /// De-duplication compares text and nothing else. A concealed entry is not a
    /// separate lane: copying the same password twice in a row still makes one entry,
    /// and an ordinary copy of the same text right after it is still a repeat.
    func testDeduplicationTreatsConcealedEntriesLikeAnyOther() {
        let store = ClipboardHistoryStore(url: makeURL())
        XCTAssertNotNil(store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(1)))
        XCTAssertNil(store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(2)))
        XCTAssertNil(store.record(text: "hunter2", origin: .otherApplication, now: date(3)))

        XCTAssertEqual(store.entries.map(\.text), ["hunter2"])
        XCTAssertEqual(store.entries.first?.isConcealed, true)
    }

    /// Nor does a concealed entry get a free slot: it counts against the cap and pushes
    /// the oldest entry out exactly as an ordinary copy would.
    func testConcealedEntriesCountAgainstTheCap() {
        let store = ClipboardHistoryStore(url: makeURL(), maxEntries: 3)
        store.record(text: "one", origin: .otherApplication, now: date(1))
        store.record(text: "two", origin: .otherApplication, now: date(2))
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(3))
        store.record(text: "four", origin: .otherApplication, now: date(4))

        XCTAssertEqual(store.entries.map(\.text), ["four", "hunter2", "two"])
    }

    func testClearRemovesConcealedEntriesFromTheListToo() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(1))
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
    }

    /// A store file written before the concealed field existed still loads, and nothing
    /// in it is treated as concealed — which also means a later write keeps it, rather
    /// than silently filtering the whole legacy file off the disk.
    func testStoreFileWrittenBeforeConcealedExistedStillLoads() throws {
        let url = makeURL()
        let legacy = """
        [
          {
            "id" : "9F1B3C4D-0000-4000-8000-00000000ABCD",
            "text" : "copied last week",
            "capturedAt" : "1970-01-01T00:00:05Z",
            "origin" : "whisperKey"
          }
        ]
        """
        try Data(legacy.utf8).write(to: url)

        let store = ClipboardHistoryStore(url: url)
        XCTAssertEqual(store.entries.map(\.text), ["copied last week"])
        XCTAssertEqual(store.entries.first?.isConcealed, false)

        store.record(text: "something new", origin: .otherApplication, now: date(9))
        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(onDisk.contains("copied last week"), "the legacy entry must survive a later write:\n\(onDisk)")
    }

    func testAnOrdinaryEntryComesBackNotConcealed() {
        let url = makeURL()
        ClipboardHistoryStore(url: url).record(text: "ordinary", origin: .otherApplication, now: date(1))

        XCTAssertEqual(ClipboardHistoryStore(url: url).entries.map(\.isConcealed), [false])
    }

    func testLoadedEntriesBeyondTheCapAreTrimmedOnInit() throws {
        let url = makeURL()
        let seed = ClipboardHistoryStore(url: url, maxEntries: 10)
        for i in 1...6 {
            seed.record(text: "entry-\(i)", origin: .otherApplication, now: date(TimeInterval(i)))
        }

        let capped = ClipboardHistoryStore(url: url, maxEntries: 2)
        XCTAssertEqual(capped.entries.map(\.text), ["entry-6", "entry-5"])
        XCTAssertEqual(ClipboardHistoryStore(url: url, maxEntries: 10).entries.count, 2)
    }

    // MARK: - Preview

    func testPreviewCollapsesNewlinesAndTruncates() {
        let entry = ClipboardEntry(text: "first line\nsecond line", capturedAt: date(1))
        XCTAssertEqual(entry.preview(), "first line second line")
        XCTAssertEqual(ClipboardEntry(text: String(repeating: "x", count: 200), capturedAt: date(1)).preview(maxLength: 10),
                       "xxxxxxxxxx…")
    }

    /// A dictated paragraph arrives with blank lines and indentation in it. Collapsing
    /// each *run* of whitespace — not merely turning every newline into its own space —
    /// is what keeps a one-line row from being mostly gaps, and is what makes the
    /// character budget count characters the reader can actually see.
    func testPreviewCollapsesRunsOfWhitespaceToASingleSpace() {
        XCTAssertEqual(ClipboardEntry(text: "a\n\nb", capturedAt: date(1)).preview(), "a b")
        XCTAssertEqual(
            ClipboardEntry(text: "line one\n\tline two", capturedAt: date(1)).preview(),
            "line one line two"
        )
        XCTAssertEqual(
            ClipboardEntry(text: "  padded \r\n\r\n  text  ", capturedAt: date(1)).preview(),
            "padded text"
        )
    }

    /// The truncation boundary, from both sides. An entry at exactly the limit is shown
    /// whole; one character more is cut and marked.
    func testPreviewTruncationBoundary() {
        let atLimit = ClipboardEntry(text: String(repeating: "y", count: 10), capturedAt: date(1))
        XCTAssertEqual(atLimit.preview(maxLength: 10), String(repeating: "y", count: 10))

        let overLimit = ClipboardEntry(text: String(repeating: "y", count: 11), capturedAt: date(1))
        XCTAssertEqual(overLimit.preview(maxLength: 10), String(repeating: "y", count: 10) + "…")
    }

    /// An entry shorter than the limit comes back untouched — no ellipsis, no padding.
    func testPreviewLeavesShortEntriesAlone() {
        let entry = ClipboardEntry(text: "short", capturedAt: date(1))
        XCTAssertEqual(entry.preview(maxLength: 80), "short")
        XCTAssertFalse(entry.preview(maxLength: 80).hasSuffix("…"))
    }

    /// The cut lands between words often enough that a trailing space before the ellipsis
    /// is the common case, and " …" reads as a gap rather than as a continuation.
    func testPreviewDoesNotLeaveASpaceBeforeTheEllipsis() {
        let entry = ClipboardEntry(text: "abcde fghij klmno", capturedAt: date(1))
        XCTAssertEqual(entry.preview(maxLength: 6), "abcde…")
    }
}
