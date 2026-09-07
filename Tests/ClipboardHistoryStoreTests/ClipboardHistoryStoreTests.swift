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
}
