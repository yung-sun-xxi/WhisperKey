import XCTest
@testable import ClipboardHistoryStore

/// One text, one row (#211): a text recorded again moves to the top instead of being
/// stored a second time, duplicates already in the file collapse, and the list never
/// shows the same text twice whatever the file holds.
final class ClipboardHistoryDeduplicationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-ClipboardHistoryDeduplicationTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The file as it is on disk, read without any store in between.
    private func entriesOnDisk(_ url: URL) throws -> [ClipboardEntry] {
        try ClipboardHistoryStore.makeDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: url))
    }

    /// Writes the file the way a build without #211 could have left it: verbatim, with
    /// whatever duplicates the caller put in. Newest first, like the store's own writes.
    private func writeRaw(_ entries: [ClipboardEntry], to url: URL) throws {
        try ClipboardHistoryStore.makeEncoder().encode(entries).write(to: url, options: [.atomic])
    }

    private func entry(_ text: String, at seconds: TimeInterval, origin: ClipboardEntryOrigin = .otherApplication) -> ClipboardEntry {
        ClipboardEntry(text: text, capturedAt: date(seconds), origin: origin)
    }

    // MARK: - 3. A text recorded again moves to the top

    /// The ticket's "copy A, B, A": A on top, B below it, no second A — in the list and
    /// in the file.
    func testATextCopiedAgainAfterAnotherMovesToTheTop() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        let first = store.record(text: "a", origin: .otherApplication, now: date(1))
        store.record(text: "b", origin: .otherApplication, now: date(2))
        let again = store.record(text: "a", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["a", "b"])
        XCTAssertEqual(store.entries.first?.capturedAt, date(3))
        XCTAssertEqual(try entriesOnDisk(url).map(\.text), ["a", "b"])
        XCTAssertNotNil(again)
        XCTAssertNotEqual(again?.id, first?.id, "the moved entry is a new entry, with a new id")
        XCTAssertEqual(store.entries.first?.id, again?.id)
    }

    func testATextBuriedDeepInTheListMovesToTheTop() {
        let store = ClipboardHistoryStore(url: makeURL())
        for (index, text) in ["one", "two", "three", "four", "five"].enumerated() {
            store.record(text: text, origin: .otherApplication, now: date(TimeInterval(index + 1)))
        }

        store.record(text: "two", origin: .otherApplication, now: date(9))

        XCTAssertEqual(store.entries.map(\.text), ["two", "five", "four", "three", "one"])
    }

    /// A repeat of the newest entry is refreshed, not rejected: same row, new time, new
    /// origin, new id.
    func testARepeatOfTheNewestEntryRefreshesIt() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "older", origin: .otherApplication, now: date(1))
        let first = store.record(text: "same", origin: .otherApplication, now: date(2))
        let second = store.record(text: "same", origin: .whisperKey, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["same", "older"])
        XCTAssertEqual(second?.capturedAt, date(3))
        XCTAssertEqual(store.entries.first, second)
        XCTAssertEqual(store.entries.first?.origin, .whisperKey)
        XCTAssertNotEqual(second?.id, first?.id)
        XCTAssertEqual(try entriesOnDisk(url), store.entries)
    }

    /// The moved entry takes the origin of the copy that moved it.
    func testAMovedEntryCarriesTheNewOrigin() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "dictated", origin: .whisperKey, now: date(1))
        store.record(text: "other", origin: .otherApplication, now: date(2))
        store.record(text: "dictated", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["dictated", "other"])
        XCTAssertEqual(store.entries.map(\.origin), [.otherApplication, .otherApplication])
    }

    /// Text is compared verbatim, as before: surrounding whitespace makes another text.
    func testTextsThatDifferOnlyInWhitespaceAreDifferentTexts() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "hello", origin: .otherApplication, now: date(1))
        store.record(text: "hello ", origin: .otherApplication, now: date(2))

        XCTAssertEqual(store.entries.map(\.text), ["hello ", "hello"])
    }

    // MARK: - 3. The shared file

    /// Two apps, one file (#140): a text one app recorded and the other records again
    /// later is in the file once, on top.
    func testATextRecordedByOneInstanceMovesToTheTopWhenTheOtherRecordsIt() throws {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)
        release.record(text: "a", origin: .otherApplication, now: date(1))
        dev.record(text: "b", origin: .otherApplication, now: date(2))

        dev.record(text: "a", origin: .otherApplication, now: date(3))

        XCTAssertEqual(try entriesOnDisk(url).map(\.text), ["a", "b"])
        XCTAssertEqual(dev.entries.map(\.text), ["a", "b"])
    }

    /// An ordinary write never shrinks a file bigger than this app's cap — except by the
    /// duplicate it replaces. Ten entries stay ten.
    func testMovingATextWithASmallCapDoesNotShrinkABiggerFile() throws {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        for i in 1...10 {
            release.record(text: "r\(i)", origin: .otherApplication, now: date(TimeInterval(i)))
        }

        let dev = ClipboardHistoryStore(url: url, maxEntries: 3)
        dev.record(text: "r4", origin: .otherApplication, now: date(20))

        XCTAssertEqual(dev.entries.map(\.text), ["r4", "r10", "r9"])
        XCTAssertEqual(
            try entriesOnDisk(url).map(\.text),
            ["r4", "r10", "r9", "r8", "r7", "r6", "r5", "r3", "r2", "r1"]
        )
    }

    /// The other build of the app shares the file and may not have #211, so it can leave
    /// one text in the file several times while this store is already open — after the
    /// cleanup on init, which runs once. Recording that text removes every older entry
    /// with it from the file, not only the newest of them. Asserted on the file: the
    /// list would hide a leftover duplicate.
    func testRecordingATextTheOtherAppLeftSeveralTimesRemovesEveryOlderOne() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        let written = [entry("A", at: 5), entry("x", at: 4), entry("A", at: 3), entry("y", at: 2), entry("A", at: 1)]
        try writeRaw(written, to: url)

        let recorded = store.record(text: "A", origin: .otherApplication, now: date(9))

        let onDisk = try entriesOnDisk(url)
        XCTAssertEqual(onDisk.map(\.text), ["A", "x", "y"])
        XCTAssertEqual(onDisk.first?.id, recorded?.id)
        XCTAssertEqual(onDisk.dropFirst().map(\.id), [written[1].id, written[3].id])
        XCTAssertEqual(store.entries.map(\.text), ["A", "x", "y"])
    }

    // MARK: - 3. Concealed entries

    /// The same for a concealed copy: every entry with that text leaves the file, however
    /// many the other app wrote. One left behind is a password on disk.
    func testAConcealedCopyOfATextTheOtherAppLeftSeveralTimesRemovesAllOfThemFromTheFile() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        let written = [entry("hunter2", at: 5), entry("x", at: 4), entry("hunter2", at: 3), entry("y", at: 2), entry("hunter2", at: 1)]
        try writeRaw(written, to: url)

        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(9))

        XCTAssertEqual(try entriesOnDisk(url), [written[1], written[3]])
        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertEqual(store.entries.map(\.text), ["hunter2", "x", "y"])
        XCTAssertEqual(store.entries.map(\.isConcealed), [true, false, false])
    }

    /// Why the moved entry needs a new id. A concealed entry remembers the file entries
    /// that were there before it, by id, and sits above the first of them. If "a" kept
    /// its id when it moved to the top, the password would be shown above it — newer
    /// than a copy made after it.
    func testAConcealedEntryStaysBelowATextMovedToTheTopAfterIt() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "a", origin: .otherApplication, now: date(1))
        store.record(text: "b", origin: .otherApplication, now: date(2))
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(3))

        store.record(text: "a", origin: .otherApplication, now: date(4))

        XCTAssertEqual(store.entries.map(\.text), ["a", "hunter2", "b"])
        XCTAssertEqual(try entriesOnDisk(url).map(\.text), ["a", "b"])
    }

    /// The same, when the moved text was the only thing below the password.
    func testAConcealedEntryStaysBelowTheOnlyOlderTextWhenItMoves() {
        let store = ClipboardHistoryStore(url: makeURL())
        store.record(text: "a", origin: .otherApplication, now: date(1))
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(2))

        store.record(text: "a", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["a", "hunter2"])
    }

    /// A concealed copy of a text that sits in the file takes it out of the file: the
    /// one entry left is the concealed one, and it lives in memory only.
    func testAConcealedCopyOfATextInTheFileRemovesItFromTheFile() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "hunter2", origin: .otherApplication, now: date(1))
        store.record(text: "other", origin: .otherApplication, now: date(2))

        let concealed = store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["hunter2", "other"])
        XCTAssertEqual(store.entries.first, concealed)
        XCTAssertEqual(store.entries.map(\.isConcealed), [true, false])
        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertEqual(ClipboardHistoryStore(url: url).entries.map(\.text), ["other"])
    }

    /// The other way round: an ordinary copy of a text held concealed replaces it, and
    /// is written like any ordinary copy.
    func testAnOrdinaryCopyOfAConcealedTextReplacesItAndIsWritten() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "token", origin: .otherApplication, isConcealed: true, now: date(1))
        store.record(text: "other", origin: .otherApplication, now: date(2))

        store.record(text: "token", origin: .otherApplication, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["token", "other"])
        XCTAssertEqual(store.entries.map(\.isConcealed), [false, false])
        XCTAssertEqual(try entriesOnDisk(url).map(\.text), ["token", "other"])
    }

    /// A concealed text copied again after something else moves to the top, still
    /// concealed, still once.
    func testAConcealedTextCopiedAgainMovesToTheTop() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(1))
        store.record(text: "other", origin: .otherApplication, now: date(2))

        store.record(text: "hunter2", origin: .otherApplication, isConcealed: true, now: date(3))

        XCTAssertEqual(store.entries.map(\.text), ["hunter2", "other"])
        XCTAssertEqual(store.entries.first?.capturedAt, date(3))
        XCTAssertEqual(try entriesOnDisk(url).map(\.text), ["other"])
    }

    // MARK: - 4. Duplicates already in the file

    /// The file as it was found on 2026-11-16: dictations alternating with one more copy
    /// of whatever was on the clipboard. Opening the store keeps the newest entry of
    /// each text — the very entry, id and time — and rewrites the file once.
    func testOpeningAFileWithDuplicatesCollapsesThemKeepingTheNewestOfEach() throws {
        let url = makeURL()
        let raw = [
            entry("X", at: 9),
            entry("third dictation", at: 9, origin: .whisperKey),
            entry("X", at: 7),
            entry("second dictation", at: 7, origin: .whisperKey),
            entry("X", at: 5),
            entry("first dictation", at: 5, origin: .whisperKey),
            entry("copied before", at: 3),
            entry("X", at: 1),
        ]
        try writeRaw(raw, to: url)

        let store = ClipboardHistoryStore(url: url)

        let expected = [raw[0], raw[1], raw[3], raw[5], raw[6]]
        XCTAssertEqual(store.entries, expected)
        XCTAssertEqual(try entriesOnDisk(url), expected)
    }

    /// The cleanup removes duplicates and nothing else: a file bigger than this app's
    /// cap keeps every distinct entry (#140).
    func testTheCleanupDoesNotTrimTheFileToThisAppsCap() throws {
        let url = makeURL()
        var raw: [ClipboardEntry] = []
        for i in (1...8).reversed() {
            raw.append(entry("X", at: TimeInterval(i * 2 + 1)))
            raw.append(entry("r\(i)", at: TimeInterval(i * 2)))
        }
        try writeRaw(raw, to: url)

        let store = ClipboardHistoryStore(url: url, maxEntries: 3)

        XCTAssertEqual(store.entries.map(\.text), ["X", "r8", "r7"])
        XCTAssertEqual(
            try entriesOnDisk(url).map(\.text),
            ["X", "r8", "r7", "r6", "r5", "r4", "r3", "r2", "r1"]
        )
    }

    /// A file with no duplicates is not rewritten on open.
    func testOpeningAFileWithoutDuplicatesLeavesItUntouched() throws {
        let url = makeURL()
        try writeRaw([entry("b", at: 2), entry("a", at: 1)], to: url)
        let before = try Data(contentsOf: url)
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64

        _ = ClipboardHistoryStore(url: url)

        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64,
            inodeBefore,
            "every write replaces the file, so an unchanged inode means nothing was written"
        )
    }

    // MARK: - 4. The list never shows a text twice

    /// The other build of the app may not have #211 and may write duplicates into the
    /// shared file while this one runs. The list still shows each text once, the newest
    /// of it; showing is not writing, so the file is left as the other app wrote it.
    func testDuplicatesWrittenByTheOtherAppLaterAreNotShownTwice() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url)
        store.record(text: "X", origin: .otherApplication, now: date(1))

        let written = [
            entry("X", at: 5),
            entry("dictated", at: 5, origin: .whisperKey),
            entry("X", at: 3),
            entry("other", at: 2),
            entry("X", at: 1),
        ]
        try writeRaw(written, to: url)
        store.reloadFromDisk()

        XCTAssertEqual(store.entries, [written[0], written[1], written[3]])
        XCTAssertEqual(try entriesOnDisk(url), written)
    }

    /// The cap counts what is shown: duplicates hidden from the list do not take rows.
    func testHiddenDuplicatesDoNotCountAgainstTheCap() throws {
        let url = makeURL()
        let store = ClipboardHistoryStore(url: url, maxEntries: 3)
        try writeRaw(
            [entry("X", at: 6), entry("a", at: 5), entry("X", at: 4), entry("b", at: 3), entry("X", at: 2), entry("c", at: 1)],
            to: url
        )
        store.reloadFromDisk()

        XCTAssertEqual(store.entries.map(\.text), ["X", "a", "b"])
    }

    /// A password this app holds concealed, and the same text written to the file later
    /// by the other app as an ordinary copy: one row, the newer one.
    func testAConcealedEntryAndALaterFileEntryWithItsTextAreShownOnce() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)
        release.record(text: "token", origin: .otherApplication, isConcealed: true, now: date(1))

        dev.record(text: "token", origin: .otherApplication, now: date(2))
        release.reloadFromDisk()

        XCTAssertEqual(release.entries.map(\.text), ["token"])
        XCTAssertEqual(release.entries.map(\.isConcealed), [false])
    }
}
