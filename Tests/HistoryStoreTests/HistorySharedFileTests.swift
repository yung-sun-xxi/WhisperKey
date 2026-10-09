import XCTest
@testable import HistoryStore

/// The release app and the dev app share `history.json` and its audio folder, with
/// different caps. Two store instances on one file stand in for the two apps (#140).
final class HistorySharedFileTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-HistorySharedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeURL() -> URL {
        tempDir.appendingPathComponent("history.json")
    }

    private var tick: TimeInterval = 0

    @discardableResult
    private func append(_ store: HistoryStore, _ text: String) -> HistoryEntry? {
        tick += 1
        return store.append(text: text, providerID: "openai", language: nil, now: Date(timeIntervalSince1970: tick))
    }

    private func pending(_ store: HistoryStore) -> HistoryEntry? {
        tick += 1
        return store.appendPendingRecognition(
            audioData: Data([1, 2, 3]),
            fileExtension: "wav",
            providerID: "openai",
            language: nil,
            audioDurationSeconds: 1,
            model: "whisper-1",
            now: Date(timeIntervalSince1970: tick)
        )
    }

    /// Everything in the file, read by a store whose cap shows all of it.
    private func textsOnDisk(_ url: URL) -> [String] {
        HistoryStore(url: url, maxEntries: HistoryStore.allowedMaxRange.upperBound).entries.map(\.text)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - Regression proof of #140

    func testTwoInstancesAppendingBothKeepTheirEntries() {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        let dev = HistoryStore(url: url, maxEntries: 10)

        append(release, "release one")
        append(dev, "dev one")
        append(release, "release two")

        XCTAssertEqual(textsOnDisk(url), ["release two", "dev one", "release one"])
    }

    func testRemoveKeepsWhatAnotherInstanceAddedAfterThisOneLoaded() throws {
        let url = makeURL()
        let seeded = try XCTUnwrap(append(HistoryStore(url: url, maxEntries: 10), "seeded"))
        let release = HistoryStore(url: url, maxEntries: 10)
        let dev = HistoryStore(url: url, maxEntries: 10)

        append(dev, "from dev")
        XCTAssertTrue(release.remove(id: seeded.id))

        XCTAssertEqual(textsOnDisk(url), ["from dev"])
    }

    func testClearKeepsWhatAnotherInstanceAddedAfterThisOneLoaded() {
        let url = makeURL()
        append(HistoryStore(url: url, maxEntries: 10), "seeded")
        let release = HistoryStore(url: url, maxEntries: 10)
        let dev = HistoryStore(url: url, maxEntries: 10)

        append(dev, "from dev")
        release.clear()

        XCTAssertEqual(textsOnDisk(url), ["from dev"])
    }

    /// Recognition finishes in the app that started it, but the entry has to be found in
    /// the file as it is now, not in a copy taken before the other app's writes.
    func testMarkRecognizedFindsAnEntryAnotherInstanceAdded() throws {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        let dev = HistoryStore(url: url, maxEntries: 10)

        let started = try XCTUnwrap(pending(dev))
        let marked = release.markRecognized(
            id: started.id, text: "done", providerID: "openai", language: nil, model: "whisper-1",
            estimatedPriceAtTime: 0.001, currency: "USD", destinationUsed: nil,
            copiedToClipboard: nil, autoPasted: nil
        )

        XCTAssertEqual(marked?.text, "done")
        XCTAssertEqual(textsOnDisk(url), ["done"])
    }

    // MARK: - Different caps on one file (owner's rule)

    /// The dev app (small cap) appending must not cut the release app's long history
    /// down to its own size.
    func testASmallCapAppendDoesNotShrinkABiggerFile() {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        for i in 1...10 { append(release, "r\(i)") }

        let dev = HistoryStore(url: url, maxEntries: 3)
        append(dev, "d1")

        XCTAssertEqual(dev.entries.map(\.text), ["d1", "r10", "r9"])
        XCTAssertEqual(textsOnDisk(url), ["d1"] + (2...10).reversed().map { "r\($0)" },
                       "the file keeps its 10, dropping only the oldest")
    }

    func testOpeningWithASmallCapDoesNotTrimTheFile() {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        for i in 1...10 { append(release, "r\(i)") }

        let dev = HistoryStore(url: url, maxEntries: 3)

        XCTAssertEqual(dev.entries.map(\.text), ["r10", "r9", "r8"])
        XCTAssertEqual(textsOnDisk(url).count, 10)
    }

    /// Audio for an entry the small-cap app does not show still belongs to the other app.
    func testOpeningWithASmallCapKeepsAudioTheFileStillReferences() throws {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        let old = try XCTUnwrap(pending(release))
        for i in 1...5 { append(release, "r\(i)") }

        let dev = HistoryStore(url: url, maxEntries: 2)

        XCTAssertTrue(dev.hasAudio(for: old), "audio of an entry still in the file was deleted")
    }

    func testACorruptFileIsKeptAsideAndNotOverwritten() throws {
        let url = makeURL()
        let garbage = Data("[{ \"text\": broken".utf8)
        try garbage.write(to: url)

        let store = HistoryStore(url: url, maxEntries: 10)
        XCTAssertTrue(store.entries.isEmpty)
        append(store, "after")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let kept = siblings.filter { $0.hasPrefix("history.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "expected one kept-aside copy, found \(siblings)")
        if let name = kept.first {
            XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(name)), garbage)
        }
        XCTAssertEqual(textsOnDisk(url), ["after"])
    }

    func testAnInstanceSeesAnotherInstancesWriteWithoutBeingAsked() {
        let url = makeURL()
        let release = HistoryStore(url: url, maxEntries: 10)
        let dev = HistoryStore(url: url, maxEntries: 10)

        append(dev, "from dev")

        XCTAssertTrue(waitUntil { release.entries.map(\.text) == ["from dev"] },
                      "release still shows \(release.entries.map(\.text))")
    }
}
