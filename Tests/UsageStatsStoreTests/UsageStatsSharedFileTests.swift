import XCTest
@testable import UsageStatsStore

/// The release app and the dev app share `usage-stats.json`. Two store instances on one
/// file stand in for the two apps: neither may lose what the other wrote (#140).
final class UsageStatsSharedFileTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-UsageStatsSharedFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeURL() -> URL {
        tempDir.appendingPathComponent("usage-stats.json")
    }

    @discardableResult
    private func record(_ store: UsageStatsStore, model: String = "whisper-1", words: Int = 1) -> UsageEntry {
        store.record(
            providerID: "openai",
            modelID: model,
            wordCount: words,
            audioDurationSeconds: 1,
            estimatedPriceAtTime: 0.001,
            currency: "USD"
        )
    }

    private func idsOnDisk(_ url: URL) -> Set<UUID> {
        Set(UsageStatsStore(url: url).entries.map(\.id))
    }

    /// Spins the main run loop, which is where the file watcher delivers its updates.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - Regression proof of #140

    /// The bug itself: the second writer used to write from a copy that never held the
    /// first writer's entry.
    func testTwoInstancesAppendingBothKeepTheirEntries() {
        let url = makeURL()
        let release = UsageStatsStore(url: url)
        let dev = UsageStatsStore(url: url)

        let fromRelease = record(release)
        let fromDev = record(dev)
        let again = record(release)

        XCTAssertEqual(idsOnDisk(url), [fromRelease.id, fromDev.id, again.id])
    }

    func testResetAllKeepsWhatAnotherInstanceAddedAfterThisOneLoaded() {
        let url = makeURL()
        let seeded = record(UsageStatsStore(url: url))
        let release = UsageStatsStore(url: url)
        let dev = UsageStatsStore(url: url)

        let fromDev = record(dev)
        release.resetAll()

        XCTAssertEqual(idsOnDisk(url), [fromDev.id], "reset must remove \(seeded.id) and nothing it never saw")
    }

    func testResetCountersKeepsWhatAnotherInstanceAddedAfterThisOneLoaded() {
        let url = makeURL()
        let seeded = record(UsageStatsStore(url: url))
        let otherModel = record(UsageStatsStore(url: url), model: "gpt-transcribe")
        let release = UsageStatsStore(url: url)
        let dev = UsageStatsStore(url: url)

        let fromDev = record(dev)
        release.resetCounters(for: [ProviderModelKey(providerID: "openai", modelID: "whisper-1")])

        XCTAssertEqual(idsOnDisk(url), [otherModel.id, fromDev.id], "\(seeded.id) alone should have gone")
    }

    func testACorruptFileIsKeptAsideAndNotOverwritten() throws {
        let url = makeURL()
        let garbage = Data("{ this is not the usage file".utf8)
        try garbage.write(to: url)

        let store = UsageStatsStore(url: url)
        XCTAssertTrue(store.entries.isEmpty)
        let entry = record(store)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let kept = siblings.filter { $0.hasPrefix("usage-stats.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "expected one kept-aside copy, found \(siblings)")
        if let name = kept.first {
            XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent(name)), garbage)
        }
        XCTAssertEqual(idsOnDisk(url), [entry.id])
    }

    /// The owner's file predates the lock. It is written exactly as before (same keys,
    /// ISO 8601 dates, an unpriced entry with no price keys at all). Loading must leave the
    /// bytes alone, and a write must keep every existing entry's fields as they were.
    func testAFileInTheExistingFormatLoadsUnchangedAndSurvivesAWrite() throws {
        let url = makeURL()
        let existing = """
        [
          {
            "audioDurationSeconds" : 12.5,
            "createdAt" : "2026-05-01T09:30:00Z",
            "currency" : "USD",
            "estimatedPriceAtTime" : 0.00125,
            "id" : "0D3A6C2E-1111-4222-8333-444455556666",
            "modelID" : "whisper-1",
            "providerID" : "openai",
            "wordCount" : 31
          },
          {
            "audioDurationSeconds" : 3,
            "createdAt" : "2026-06-02T18:00:00Z",
            "id" : "0D3A6C2E-7777-4888-9999-AAAABBBBCCCC",
            "modelID" : "whisper-large-v3",
            "providerID" : "groq",
            "wordCount" : 7
          }
        ]
        """
        try Data(existing.utf8).write(to: url)

        let store = UsageStatsStore(url: url)
        XCTAssertEqual(store.entries.map(\.wordCount), [31, 7])
        XCTAssertEqual(store.entries.last?.estimatedPriceAtTime, nil)
        XCTAssertEqual(store.entries.first?.createdAt, ISO8601DateFormatter().date(from: "2026-05-01T09:30:00Z"))
        XCTAssertEqual(try Data(contentsOf: url), Data(existing.utf8), "loading must not rewrite the file")

        record(store)

        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any]
        let original = try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [Any]
        XCTAssertEqual(rewritten?.count, 3)
        XCTAssertEqual(rewritten?.prefix(2).map { $0 as? NSDictionary }, original?.map { $0 as? NSDictionary })
    }

    /// The file watcher is what lets an app that runs for days see the other app's
    /// entries without restarting.
    func testAnInstanceSeesAnotherInstancesWriteWithoutBeingAsked() {
        let url = makeURL()
        let release = UsageStatsStore(url: url)
        let dev = UsageStatsStore(url: url)

        let fromDev = record(dev)

        XCTAssertTrue(waitUntil { release.entries.map(\.id) == [fromDev.id] },
                      "release still shows \(release.entries.map(\.id))")
    }
}
