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

    // MARK: - Total across models / per-model breakdown

    private let miniKey = ProviderModelKey(providerID: "openai", modelID: "gpt-4o-mini-transcribe")
    private let transcribeKey = ProviderModelKey(providerID: "openai", modelID: "gpt-transcribe")
    private let groqKey = ProviderModelKey(providerID: "groq", modelID: "whisper-large-v3")

    @discardableResult
    private func record(
        _ store: UsageStatsStore,
        _ key: ProviderModelKey,
        words: Int,
        seconds: TimeInterval,
        price: Double?,
        currency: String?,
        at createdAt: Date
    ) -> UsageEntry {
        store.record(
            providerID: key.providerID,
            modelID: key.modelID,
            wordCount: words,
            audioDurationSeconds: seconds,
            estimatedPriceAtTime: price,
            currency: currency,
            now: createdAt
        )
    }

    /// The issue's case: 32.9 h on one model and 2.3 h on another read as two
    /// different "totals". The total must be their sum, and the breakdown must
    /// list both, longest first, whatever order they were recorded in.
    func testTotalSummarySumsEveryModelAndBreakdownListsEachLongestFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        // The shorter model is recorded first so insertion order is not duration order.
        record(store, transcribeKey, words: 1_000, seconds: 4_000, price: 0.4, currency: "USD", at: date(3, calendar: calendar, now: now))
        record(store, miniKey, words: 50_000, seconds: 60_000, price: 3.0, currency: "USD", at: date(200, calendar: calendar, now: now))
        record(store, transcribeKey, words: 1_300, seconds: 4_280, price: 0.43, currency: "USD", at: date(1, calendar: calendar, now: now))
        record(store, miniKey, words: 48_000, seconds: 58_440, price: 2.92, currency: "USD", at: date(10, calendar: calendar, now: now))

        let total = store.totalSummary(range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(total.wordCount, 100_300)
        XCTAssertEqual(total.audioDurationSeconds, 126_720) // 35.2 h = 32.9 h + 2.3 h
        XCTAssertEqual(total.estimatedCost ?? -1, 6.75, accuracy: 1e-9)
        XCTAssertEqual(total.currency, "USD")

        let rows = store.breakdown(range: .allTime, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), [miniKey, transcribeKey])
        XCTAssertEqual(rows.first?.summary.audioDurationSeconds, 118_440) // 32.9 h
        XCTAssertEqual(rows.first?.summary.wordCount, 98_000)
        XCTAssertEqual(rows.first?.summary.estimatedCost ?? -1, 5.92, accuracy: 1e-9)
        XCTAssertEqual(rows.last?.summary.audioDurationSeconds, 8_280) // 2.3 h
        XCTAssertEqual(rows.last?.summary.wordCount, 2_300)
        XCTAssertEqual(rows.last?.summary.estimatedCost ?? -1, 0.83, accuracy: 1e-9)

        XCTAssertEqual(rows.reduce(0) { $0 + $1.summary.wordCount }, total.wordCount)
        XCTAssertEqual(rows.reduce(0.0) { $0 + $1.summary.audioDurationSeconds }, total.audioDurationSeconds)
    }

    func testBreakdownBreaksDurationTiesByProviderThenModel() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        record(store, transcribeKey, words: 1, seconds: 60, price: 0.01, currency: "USD", at: date(0, calendar: calendar, now: now))
        record(store, groqKey, words: 1, seconds: 60, price: 0.01, currency: "USD", at: date(0, calendar: calendar, now: now))
        record(store, miniKey, words: 1, seconds: 60, price: 0.01, currency: "USD", at: date(0, calendar: calendar, now: now))

        let rows = store.breakdown(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), [groqKey, miniKey, transcribeKey])
    }

    /// A period that spans two models: entries before the period's start drop
    /// out of the total and out of their model's row, and a model whose entries
    /// all fall outside the period gets no row.
    func testTotalAndBreakdownHonourTheRangeAcrossModels() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        record(store, miniKey, words: 10, seconds: 600, price: 0.03, currency: "USD", at: date(0, calendar: calendar, now: now))
        record(store, miniKey, words: 999, seconds: 99_999, price: 9.99, currency: "USD", at: date(10, calendar: calendar, now: now))
        record(store, transcribeKey, words: 20, seconds: 300, price: 0.02, currency: "USD", at: date(6, calendar: calendar, now: now))
        record(store, transcribeKey, words: 888, seconds: 88_888, price: 8.88, currency: "USD", at: date(7, calendar: calendar, now: now))
        record(store, groqKey, words: 777, seconds: 77_777, price: 7.77, currency: "USD", at: date(20, calendar: calendar, now: now))

        let total = store.totalSummary(range: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(total.wordCount, 30)
        XCTAssertEqual(total.audioDurationSeconds, 900)
        XCTAssertEqual(total.estimatedCost ?? -1, 0.05, accuracy: 1e-9)

        let rows = store.breakdown(range: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), [miniKey, transcribeKey])
        XCTAssertEqual(rows.map(\.summary.wordCount), [10, 20])
        XCTAssertEqual(rows.map(\.summary.audioDurationSeconds), [600, 300])
    }

    func testTotalDropsCostAcrossMixedCurrenciesWhileEachRowKeepsItsOwn() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        record(store, miniKey, words: 10, seconds: 600, price: 0.03, currency: "USD", at: date(0, calendar: calendar, now: now))
        record(store, groqKey, words: 5, seconds: 300, price: 0.02, currency: "EUR", at: date(0, calendar: calendar, now: now))

        let total = store.totalSummary(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.wordCount, 15)
        XCTAssertNil(total.estimatedCost)
        XCTAssertNil(total.currency)

        let rows = store.breakdown(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), [miniKey, groqKey])
        XCTAssertEqual(rows.map(\.summary.estimatedCost), [0.03, 0.02])
        XCTAssertEqual(rows.map(\.summary.currency), ["USD", "EUR"])
    }

    func testTotalDropsCostWhenOneModelIsUnpricedWhileThePricedRowKeepsIt() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        let store = UsageStatsStore(url: makeURL())

        record(store, miniKey, words: 10, seconds: 600, price: 0.03, currency: "USD", at: date(0, calendar: calendar, now: now))
        record(store, groqKey, words: 5, seconds: 300, price: nil, currency: nil, at: date(0, calendar: calendar, now: now))

        let total = store.totalSummary(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.wordCount, 15)
        XCTAssertEqual(total.audioDurationSeconds, 900)
        XCTAssertNil(total.estimatedCost)

        let rows = store.breakdown(range: .today, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), [miniKey, groqKey])
        XCTAssertEqual(rows.first?.summary.estimatedCost, 0.03)
        XCTAssertEqual(rows.first?.summary.currency, "USD")
        XCTAssertNil(rows.last?.summary.estimatedCost)
    }

    func testTotalAndBreakdownOfAnEmptyStore() {
        let store = UsageStatsStore(url: makeURL())

        XCTAssertEqual(store.totalSummary(range: .allTime), .empty)
        XCTAssertEqual(store.breakdown(range: .allTime), [])
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
