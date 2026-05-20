import XCTest
@testable import UsageStatsStore
import TranscriptionProvider
import HistoryStore

final class UsageStatsStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-UsageStatsStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    private func date(_ daysBeforeNow: Int, hour: Int = 12, calendar: Calendar = .current, now: Date) -> Date {
        let startOfNow = calendar.startOfDay(for: now)
        let shifted = calendar.date(byAdding: .day, value: -daysBeforeNow, to: startOfNow)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
    }

    // MARK: - Recording / persistence

    func testRecordAppendsEntryAndPersists() {
        let url = makeURL()
        let store = UsageStatsStore(url: url)
        _ = store.record(
            providerID: "openai",
            modelID: "whisper-1",
            wordCount: 12,
            audioDurationSeconds: 30,
            estimatedPriceAtTime: 0.003,
            currency: "USD"
        )

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.providerID, "openai")

        let reloaded = UsageStatsStore(url: url)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.wordCount, 12)
    }

    func testRecordClampsNegativeInputs() {
        let store = UsageStatsStore(url: makeURL())
        _ = store.record(
            providerID: "openai",
            modelID: "whisper-1",
            wordCount: -5,
            audioDurationSeconds: -3,
            estimatedPriceAtTime: nil,
            currency: nil
        )
        XCTAssertEqual(store.entries.first?.wordCount, 0)
        XCTAssertEqual(store.entries.first?.audioDurationSeconds, 0)
    }

    // MARK: - Summary / range filtering

    func testSummaryFiltersByTodayRange() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 10, audioDurationSeconds: 60,
                         estimatedPriceAtTime: 0.006, currency: "USD",
                         now: date(0, calendar: calendar, now: now))
        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 100, audioDurationSeconds: 600,
                         estimatedPriceAtTime: 0.06, currency: "USD",
                         now: date(1, calendar: calendar, now: now))

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 10)
        XCTAssertEqual(summary.audioDurationSeconds, 60)
        XCTAssertEqual(summary.estimatedCost, 0.006)
    }

    func testSummaryLast7DaysIncludesTodayAndPreviousSixDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        for offset in 0...10 {
            _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                             estimatedPriceAtTime: 0.001, currency: "USD",
                             now: date(offset, calendar: calendar, now: now))
        }

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 7)
    }

    func testSummaryLast30DaysIncludesPreviousTwentyNineDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        for offset in 0...40 {
            _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                             estimatedPriceAtTime: 0.001, currency: "USD",
                             now: date(offset, calendar: calendar, now: now))
        }

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .last30Days, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 30)
    }

    func testSummaryAllTimeReturnsEverything() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        for offset in 0...100 {
            _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 2, audioDurationSeconds: 5,
                             estimatedPriceAtTime: 0.01, currency: "USD",
                             now: date(offset, calendar: calendar, now: now))
        }

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 101 * 2)
    }

    // MARK: - Model scoping

    func testSummaryScopesByProviderAndModel() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 10, audioDurationSeconds: 60,
                         estimatedPriceAtTime: 0.006, currency: "USD",
                         now: date(0, calendar: calendar, now: now))
        _ = store.record(providerID: "openai", modelID: "gpt-4o-mini-transcribe", wordCount: 99, audioDurationSeconds: 99,
                         estimatedPriceAtTime: 0.99, currency: "USD",
                         now: date(0, calendar: calendar, now: now))
        _ = store.record(providerID: "groq", modelID: "whisper-large-v3", wordCount: 5, audioDurationSeconds: 5,
                         estimatedPriceAtTime: 0.005, currency: "USD",
                         now: date(0, calendar: calendar, now: now))

        let whisper = store.summary(providerID: "openai", modelID: "whisper-1", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(whisper.wordCount, 10)

        let mini = store.summary(providerID: "openai", modelID: "gpt-4o-mini-transcribe", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(mini.wordCount, 99)

        let groq = store.summary(providerID: "groq", modelID: "whisper-large-v3", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(groq.wordCount, 5)
    }

    func testSummaryHandlesMixedCurrenciesByDroppingCost() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD",
                         now: date(0, calendar: calendar, now: now))
        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.02, currency: "EUR",
                         now: date(0, calendar: calendar, now: now))

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 2)
        XCTAssertNil(summary.estimatedCost)
        XCTAssertNil(summary.currency)
    }

    func testSummaryDropsCostWhenSomeEntriesHaveNoPrice() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD",
                         now: date(0, calendar: calendar, now: now))
        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: nil, currency: nil,
                         now: date(0, calendar: calendar, now: now))

        let summary = store.summary(providerID: "openai", modelID: "whisper-1", range: .today, now: now, calendar: calendar)
        XCTAssertEqual(summary.wordCount, 2)
        XCTAssertNil(summary.estimatedCost)
    }

    // MARK: - Reset

    func testResetCountersDeletesSelectedProviderModelOnly() {
        let store = UsageStatsStore(url: makeURL())
        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD")
        _ = store.record(providerID: "openai", modelID: "gpt-4o-mini-transcribe", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD")
        _ = store.record(providerID: "groq", modelID: "whisper-large-v3", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD")

        store.resetCounters(for: [ProviderModelKey(providerID: "openai", modelID: "whisper-1")])

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(store.entries.contains { $0.providerID == "openai" && $0.modelID == "whisper-1" })
    }

    func testResetAllClearsEverything() {
        let url = makeURL()
        let store = UsageStatsStore(url: url)
        _ = store.record(providerID: "openai", modelID: "whisper-1", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD")
        _ = store.record(providerID: "groq", modelID: "whisper-large-v3", wordCount: 1, audioDurationSeconds: 1,
                         estimatedPriceAtTime: 0.01, currency: "USD")

        store.resetAll()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = UsageStatsStore(url: url)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    // MARK: - Pricing rule coverage

    func testEveryOpenAIModelHasPricingRule() {
        for model in OpenAIProvider.Model.allCases {
            let estimate = TranscriptionCostEstimator.estimate(
                providerID: "openai",
                model: model.rawValue,
                audioDurationSeconds: 60
            )
            XCTAssertNotNil(
                estimate,
                "OpenAI model \(model.rawValue) has no pricing rule in TranscriptionCostEstimator"
            )
            XCTAssertEqual(estimate?.currency, "USD")
            XCTAssertEqual(estimate?.amount ?? -1, estimate?.amount ?? -1, accuracy: 0)
            XCTAssertGreaterThan(estimate?.amount ?? 0, 0)
        }
    }

    func testEveryGroqModelHasPricingRule() {
        for model in GroqProvider.Model.allCases {
            let estimate = TranscriptionCostEstimator.estimate(
                providerID: "groq",
                model: model.rawValue,
                audioDurationSeconds: 60
            )
            XCTAssertNotNil(
                estimate,
                "Groq model \(model.rawValue) has no pricing rule in TranscriptionCostEstimator"
            )
            XCTAssertEqual(estimate?.currency, "USD")
            XCTAssertGreaterThan(estimate?.amount ?? 0, 0)
        }
    }
}
