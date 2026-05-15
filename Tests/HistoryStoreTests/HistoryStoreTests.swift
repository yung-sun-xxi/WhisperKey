import XCTest
@testable import HistoryStore

final class HistoryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Append / ordering

    func testAppendInsertsNewestFirst() {
        let store = HistoryStore(url: makeURL())
        _ = store.append(text: "first", providerID: "openai", language: "en", now: Date(timeIntervalSince1970: 1))
        _ = store.append(text: "second", providerID: "openai", language: "en", now: Date(timeIntervalSince1970: 2))
        _ = store.append(text: "third", providerID: "openai", language: nil, now: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(store.entries.map(\.text), ["third", "second", "first"])
    }

    // MARK: - Rotation when max exceeded

    func testAppendBeyondMaxRotatesOutOldest() {
        let store = HistoryStore(url: makeURL(), maxEntries: 3)
        for i in 1...5 {
            _ = store.append(text: "msg-\(i)", providerID: "openai", language: nil,
                             now: Date(timeIntervalSince1970: TimeInterval(i)))
        }

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.text), ["msg-5", "msg-4", "msg-3"])
    }

    func testZeroMaxEntriesDropsAppends() {
        let store = HistoryStore(url: makeURL(), maxEntries: 0)
        _ = store.append(text: "anything", providerID: "openai", language: nil)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Persistence round-trip

    func testEntriesSurviveReload() throws {
        let url = makeURL()
        do {
            let store = HistoryStore(url: url, maxEntries: 10)
            _ = store.append(
                text: "alpha beta",
                providerID: "openai",
                language: "en",
                now: Date(timeIntervalSince1970: 100),
                audioDurationSeconds: 4,
                model: "whisper-1",
                destinationUsed: "clipboard",
                copiedToClipboard: true,
                autoPasted: false
            )
            _ = store.append(text: "beta", providerID: "openai", language: nil, now: Date(timeIntervalSince1970: 200))
        }

        let reloaded = HistoryStore(url: url, maxEntries: 10)
        XCTAssertEqual(reloaded.entries.map(\.text), ["beta", "alpha beta"])
        XCTAssertEqual(reloaded.entries.first?.language, nil)
        XCTAssertEqual(reloaded.entries.last?.language, "en")
        XCTAssertEqual(reloaded.entries.last?.wordCount, 2)
        XCTAssertEqual(reloaded.entries.last?.audioDurationSeconds, 4)
        XCTAssertEqual(reloaded.entries.last?.model, "whisper-1")
        XCTAssertEqual(reloaded.entries.last?.destinationUsed, "clipboard")
        XCTAssertEqual(reloaded.entries.last?.copiedToClipboard, true)
        XCTAssertEqual(reloaded.entries.last?.autoPasted, false)
    }

    func testJSONUsesISO8601Dates() throws {
        let url = makeURL()
        let store = HistoryStore(url: url, maxEntries: 5)
        _ = store.append(text: "x", providerID: "openai", language: "en", now: Date(timeIntervalSince1970: 0))

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"createdAt\""))
        XCTAssertTrue(raw.contains("1970-01-01T"), "expected ISO8601 createdAt, got: \(raw)")
    }

    // MARK: - Max-size resize

    func testReducingMaxEntriesTrimsExisting() {
        let url = makeURL()
        let store = HistoryStore(url: url, maxEntries: 5)
        for i in 1...5 {
            _ = store.append(text: "n-\(i)", providerID: "openai", language: nil,
                             now: Date(timeIntervalSince1970: TimeInterval(i)))
        }

        store.setMaxEntries(2)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.text), ["n-5", "n-4"])

        let reloaded = HistoryStore(url: url, maxEntries: 5)
        XCTAssertEqual(reloaded.entries.map(\.text), ["n-5", "n-4"], "trim must persist to disk")
    }

    func testIncreasingMaxEntriesIsNoOp() {
        let store = HistoryStore(url: makeURL(), maxEntries: 2)
        _ = store.append(text: "a", providerID: "openai", language: nil)
        _ = store.append(text: "b", providerID: "openai", language: nil)
        store.setMaxEntries(50)
        XCTAssertEqual(store.entries.map(\.text), ["b", "a"])
        XCTAssertEqual(store.maxEntries, 50)
    }

    func testMaxEntriesIsClampedToAllowedRange() {
        let store = HistoryStore(url: makeURL(), maxEntries: 9_999)
        XCTAssertEqual(store.maxEntries, 1000)
        store.setMaxEntries(-5)
        XCTAssertEqual(store.maxEntries, 0)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Initial load applies max

    func testLoadingTrimsToConfiguredMax() throws {
        let url = makeURL()
        let pre = HistoryStore(url: url, maxEntries: 100)
        for i in 1...20 {
            _ = pre.append(text: "p-\(i)", providerID: "openai", language: nil,
                           now: Date(timeIntervalSince1970: TimeInterval(i)))
        }

        let reduced = HistoryStore(url: url, maxEntries: 5)
        XCTAssertEqual(reduced.entries.count, 5)
        XCTAssertEqual(reduced.entries.first?.text, "p-20")

        let reloaded = HistoryStore(url: url, maxEntries: 5)
        XCTAssertEqual(reloaded.entries.count, 5, "trim must have been written back to disk")
    }

    // MARK: - Clear

    func testClearEmptiesAndPersists() throws {
        let url = makeURL()
        let store = HistoryStore(url: url, maxEntries: 5)
        _ = store.append(text: "x", providerID: "openai", language: nil)
        XCTAssertFalse(store.entries.isEmpty)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = HistoryStore(url: url, maxEntries: 5)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    // MARK: - Atomic write — verify no orphan tmp files left behind

    func testNoTempFilesRemainAfterAppend() throws {
        let store = HistoryStore(url: makeURL(), maxEntries: 5)
        _ = store.append(text: "x", providerID: "openai", language: nil)
        _ = store.append(text: "y", providerID: "openai", language: nil)

        let dir = makeURL().deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tempLeftovers = contents.filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(tempLeftovers.isEmpty, "leftover tmp files: \(tempLeftovers)")
    }

    // MARK: - Preview helper

    func testPreviewTruncatesAndCollapsesNewlines() {
        let entry = HistoryEntry(
            text: String(repeating: "x", count: 200),
            createdAt: Date(),
            providerID: "openai",
            language: nil
        )
        let preview = entry.preview(maxLength: 50)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(preview.count, 51) // 50 chars + ellipsis

        let multiline = HistoryEntry(text: "a\nb\nc", createdAt: Date(), providerID: "openai", language: nil)
        XCTAssertEqual(multiline.preview(), "a b c")
    }

    // MARK: - Schema round-trip directly

    func testSchemaRoundTrip() throws {
        let original = [
            HistoryEntry(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                text: "hello",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                providerID: "openai",
                language: "ru",
                audioDurationSeconds: 1.5,
                wordCount: 1,
                model: "whisper-1",
                estimatedPriceAtTime: 0.01,
                currency: "USD",
                destinationUsed: "clipboardAndAutoPaste",
                copiedToClipboard: true,
                autoPasted: true,
                estimatedSavedSecondsAtTime: 0
            )
        ]
        let data = try HistoryStore.makeEncoder().encode(original)
        let decoded = try HistoryStore.makeDecoder().decode([HistoryEntry].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyProviderIDSchemaStillDecodes() throws {
        let json = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "text": "legacy entry",
            "createdAt": "2024-01-01T00:00:00Z",
            "providerID": "openai",
            "language": "en"
          }
        ]
        """.data(using: .utf8)!

        let decoded = try HistoryStore.makeDecoder().decode([HistoryEntry].self, from: json)
        XCTAssertEqual(decoded.first?.providerID, "openai")
        XCTAssertEqual(decoded.first?.provider, "openai")
        XCTAssertEqual(decoded.first?.wordCount, 2)
    }

    func testTodayUsageSummaryUsesLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let entries = [
            HistoryEntry(
                text: "one two three",
                createdAt: today,
                providerID: "openai",
                language: "en",
                audioDurationSeconds: 30,
                wordCount: 3,
                estimatedPriceAtTime: 0.02,
                currency: "USD",
                estimatedSavedSecondsAtTime: 12
            ),
            HistoryEntry(
                text: "four five",
                createdAt: today,
                providerID: "openai",
                language: "en",
                audioDurationSeconds: 20,
                wordCount: 2,
                estimatedPriceAtTime: 0.03,
                currency: "USD",
                estimatedSavedSecondsAtTime: 8
            ),
            HistoryEntry(
                text: "old",
                createdAt: yesterday,
                providerID: "openai",
                language: "en",
                audioDurationSeconds: 99,
                wordCount: 1,
                estimatedPriceAtTime: 99,
                currency: "USD",
                estimatedSavedSecondsAtTime: 99
            ),
        ]

        let summary = HistoryUsageSummary.today(from: entries, now: today, calendar: calendar)
        XCTAssertEqual(summary.audioDurationSeconds, 50)
        XCTAssertEqual(summary.wordCount, 5)
        XCTAssertEqual(summary.estimatedCost ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(summary.currency, "USD")
        XCTAssertEqual(summary.estimatedSavedSeconds, 20)
    }

    func testTodayUsageSummaryIgnoresEntriesWithIncompleteCostMetadata() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            HistoryEntry(
                text: "priced",
                createdAt: now,
                providerID: "openai",
                language: nil,
                audioDurationSeconds: 12,
                estimatedPriceAtTime: 0.02,
                currency: "USD"
            ),
            HistoryEntry(
                text: "unpriced",
                createdAt: now,
                providerID: "groq",
                language: nil,
                audioDurationSeconds: 12
            ),
        ]

        let summary = HistoryUsageSummary.today(from: entries, now: now)
        XCTAssertEqual(summary.wordCount, 1)
        XCTAssertEqual(summary.estimatedCost, 0.02)
        XCTAssertEqual(summary.currency, "USD")
    }

    func testTodayUsageSummaryIgnoresLegacyEntriesWithoutCostMetadata() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            HistoryEntry(
                text: "legacy words should not count",
                createdAt: now,
                providerID: "openai",
                language: nil
            )
        ]

        let summary = HistoryUsageSummary.today(from: entries, now: now)
        XCTAssertEqual(summary.audioDurationSeconds, 0)
        XCTAssertEqual(summary.wordCount, 0)
        XCTAssertEqual(summary.estimatedCost, 0)
        XCTAssertEqual(summary.currency, "USD")
    }

    func testTodayUsageSummaryIgnoresIntermediateEntriesWithDurationButNoCost() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            HistoryEntry(
                text: "duration exists but cost is missing",
                createdAt: now,
                providerID: "openai",
                language: nil,
                audioDurationSeconds: 10
            )
        ]

        let summary = HistoryUsageSummary.today(from: entries, now: now)
        XCTAssertEqual(summary.audioDurationSeconds, 0)
        XCTAssertEqual(summary.wordCount, 0)
        XCTAssertEqual(summary.estimatedCost, 0)
        XCTAssertEqual(summary.currency, "USD")
    }

    func testTranscriptionCostEstimatorUsesKnownProviderPrices() {
        let openAI = TranscriptionCostEstimator.estimate(
            providerID: "openai",
            model: "gpt-4o-mini-transcribe",
            audioDurationSeconds: 60
        )
        XCTAssertEqual(openAI?.amount ?? 0, 0.003, accuracy: 0.000001)
        XCTAssertEqual(openAI?.currency, "USD")

        let groq = TranscriptionCostEstimator.estimate(
            providerID: "groq",
            model: "whisper-large-v3-turbo",
            audioDurationSeconds: 3_600
        )
        XCTAssertEqual(groq?.amount ?? 0, 0.04, accuracy: 0.000001)
        XCTAssertEqual(groq?.currency, "USD")
    }

    func testGroqCostEstimatorAppliesTenSecondMinimum() {
        let estimate = TranscriptionCostEstimator.estimate(
            providerID: "groq",
            model: "whisper-large-v3-turbo",
            audioDurationSeconds: 1
        )
        XCTAssertEqual(estimate?.amount ?? 0, 10.0 / 3_600 * 0.04, accuracy: 0.000001)
    }
}
