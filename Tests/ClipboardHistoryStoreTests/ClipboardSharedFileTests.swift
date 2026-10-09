import XCTest
@testable import ClipboardHistoryStore

/// The release app and the dev app share `clipboard-history.json`, with possibly
/// different caps. Two store instances on one file stand in for the two apps (#140).
final class ClipboardSharedFileTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-ClipboardSharedFileTests-\(UUID().uuidString)", isDirectory: true)
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

    private var tick: TimeInterval = 0

    @discardableResult
    private func record(_ store: ClipboardHistoryStore, _ text: String, concealed: Bool = false) -> ClipboardEntry? {
        tick += 1
        return store.record(text: text, origin: .otherApplication, isConcealed: concealed,
                            now: Date(timeIntervalSince1970: tick))
    }

    private func textsOnDisk(_ url: URL) -> [String] {
        ClipboardHistoryStore(url: url, maxEntries: ClipboardHistoryStore.allowedMaxRange.upperBound).entries.map(\.text)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - Regression proof of #140

    func testTwoInstancesRecordingBothKeepTheirEntries() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)

        record(release, "release one")
        record(dev, "dev one")
        record(release, "release two")

        XCTAssertEqual(textsOnDisk(url), ["release two", "dev one", "release one"])
    }

    func testClearKeepsWhatAnotherInstanceAddedAfterThisOneLoaded() {
        let url = makeURL()
        record(ClipboardHistoryStore(url: url, maxEntries: 10), "seeded")
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)

        record(dev, "from dev")
        release.clear()

        XCTAssertEqual(textsOnDisk(url), ["from dev"])
    }

    /// Both apps watch the same pasteboard, so one copy reaches both. It must land in the
    /// file once: the repeat check compares against the file's newest entry, not against
    /// a copy taken before the other app recorded it.
    func testOneCopySeenByBothInstancesLandsOnce() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)

        XCTAssertNotNil(record(release, "copied once"))
        XCTAssertNil(record(dev, "copied once"))

        XCTAssertEqual(textsOnDisk(url), ["copied once"])
    }

    func testASmallCapRecordDoesNotShrinkABiggerFile() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        for i in 1...10 { record(release, "r\(i)") }

        let dev = ClipboardHistoryStore(url: url, maxEntries: 3)
        record(dev, "d1")

        XCTAssertEqual(dev.entries.map(\.text), ["d1", "r10", "r9"])
        XCTAssertEqual(textsOnDisk(url), ["d1"] + (2...10).reversed().map { "r\($0)" })
    }

    func testOpeningWithASmallCapDoesNotTrimTheFile() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        for i in 1...10 { record(release, "r\(i)") }

        let dev = ClipboardHistoryStore(url: url, maxEntries: 3)

        XCTAssertEqual(dev.entries.map(\.text), ["r10", "r9", "r8"])
        XCTAssertEqual(textsOnDisk(url).count, 10)
    }

    /// A concealed entry lives only in the memory of the app that saw it. When the other
    /// app writes, this app's list takes the new file contents and keeps its own concealed
    /// entry in place; the file still never holds it.
    func testAConcealedEntrySurvivesTheOtherInstancesWritesAndStaysOffDisk() throws {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)

        record(release, "hunter2", concealed: true)
        record(dev, "from dev")
        record(release, "from release")

        XCTAssertEqual(release.entries.map(\.text), ["from release", "from dev", "hunter2"])
        let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("hunter2"), "the concealed text must not be on disk:\n\(onDisk)")
        XCTAssertEqual(textsOnDisk(url), ["from release", "from dev"])
    }

    func testACorruptFileIsKeptAsideAndNotOverwritten() throws {
        let url = makeURL()
        let garbage = Data("not json at all".utf8)
        try garbage.write(to: url)

        let store = ClipboardHistoryStore(url: url, maxEntries: 10)
        XCTAssertTrue(store.entries.isEmpty)
        record(store, "after")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let kept = siblings.filter { $0.hasPrefix("clipboard-history.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "expected one kept-aside copy, found \(siblings)")
        if let name = kept.first {
            XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(name)), garbage)
        }
        XCTAssertEqual(textsOnDisk(url), ["after"])
    }

    func testAnInstanceSeesAnotherInstancesWriteWithoutBeingAsked() {
        let url = makeURL()
        let release = ClipboardHistoryStore(url: url, maxEntries: 10)
        let dev = ClipboardHistoryStore(url: url, maxEntries: 10)

        record(dev, "from dev")

        XCTAssertTrue(waitUntil { release.entries.map(\.text) == ["from dev"] },
                      "release still shows \(release.entries.map(\.text))")
    }
}
