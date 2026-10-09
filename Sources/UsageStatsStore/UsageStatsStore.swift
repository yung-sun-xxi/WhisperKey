import Foundation
import Combine
import SharedJSONFile

public struct UsageEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let providerID: String
    public let modelID: String
    public let wordCount: Int
    public let audioDurationSeconds: TimeInterval
    public let estimatedPriceAtTime: Double?
    public let currency: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        providerID: String,
        modelID: String,
        wordCount: Int,
        audioDurationSeconds: TimeInterval,
        estimatedPriceAtTime: Double? = nil,
        currency: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelID = modelID
        self.wordCount = wordCount
        self.audioDurationSeconds = audioDurationSeconds
        self.estimatedPriceAtTime = estimatedPriceAtTime
        self.currency = currency
    }
}

public struct ProviderModelKey: Hashable, Codable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public enum UsageStatsRange: String, CaseIterable, Codable, Sendable {
    case today
    case last7Days
    case last30Days
    case allTime

    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .allTime: return "All Time"
        }
    }

    public var compactLabel: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7d"
        case .last30Days: return "30d"
        case .allTime: return "All"
        }
    }
}

public struct UsageSummary: Equatable, Sendable {
    public let wordCount: Int
    public let audioDurationSeconds: TimeInterval
    public let estimatedCost: Double?
    public let currency: String?

    public init(
        wordCount: Int,
        audioDurationSeconds: TimeInterval,
        estimatedCost: Double?,
        currency: String?
    ) {
        self.wordCount = wordCount
        self.audioDurationSeconds = audioDurationSeconds
        self.estimatedCost = estimatedCost
        self.currency = currency
    }

    public static let empty = UsageSummary(
        wordCount: 0,
        audioDurationSeconds: 0,
        estimatedCost: 0,
        currency: "USD"
    )
}

/// One provider+model's usage over a period, as listed in the breakdown window.
public struct UsageBreakdownRow: Equatable, Sendable, Identifiable {
    public let key: ProviderModelKey
    public let summary: UsageSummary

    public var id: ProviderModelKey { key }

    public init(key: ProviderModelKey, summary: UsageSummary) {
        self.key = key
        self.summary = summary
    }
}

public final class UsageStatsStore: ObservableObject, @unchecked Sendable {
    /// Everything in the file, oldest first, as this instance last saw it.
    @Published public private(set) var entries: [UsageEntry] = []

    private let url: URL
    private let file: SharedJSONFile<UsageEntry>
    private var watcher: DirectoryWatcher?

    /// The file is shared with the other build of the app (release and dev), so every
    /// change goes through `SharedJSONFile` and the directory is watched for the other
    /// app's writes (#140).
    public init(url: URL? = nil) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.file = SharedJSONFile(url: resolvedURL, encoder: Self.makeEncoder(), decoder: Self.makeDecoder())
        try? FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        // Watch before the first read, so a write landing between the two is not missed.
        self.watcher = DirectoryWatcher(directory: file.directory) { [weak self] in
            self?.reloadFromDisk()
        }
        self.entries = (try? file.load()) ?? []
    }

    /// Picks up another process's writes. The directory watcher calls this on the main
    /// queue; `entries` is republished only when the file's contents actually changed.
    public func reloadFromDisk() {
        guard let fresh = try? file.reloadIfChanged() else { return }
        publish(fresh)
    }

    public var fileURL: URL { url }

    @discardableResult
    public func record(
        providerID: String,
        modelID: String,
        wordCount: Int,
        audioDurationSeconds: TimeInterval,
        estimatedPriceAtTime: Double?,
        currency: String?,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> UsageEntry {
        let entry = UsageEntry(
            id: id,
            createdAt: now,
            providerID: providerID,
            modelID: modelID,
            wordCount: max(wordCount, 0),
            audioDurationSeconds: max(audioDurationSeconds, 0),
            estimatedPriceAtTime: estimatedPriceAtTime,
            currency: currency
        )
        do {
            try file.update { $0.append(entry) }
            publish(file.contents)
        } catch {
            // Non-fatal: usage data is best-effort. Shown for this session only.
            publish(entries + [entry])
        }
        return entry
    }

    public func summary(
        providerID: String,
        modelID: String,
        range: UsageStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageSummary {
        let filtered = filteredEntries(
            providerID: providerID,
            modelID: modelID,
            range: range,
            now: now,
            calendar: calendar
        )
        return Self.summarize(filtered)
    }

    /// Usage across every provider and model in the range. The cost is summed only
    /// when every entry in the range is priced in one currency; otherwise it is nil.
    public func totalSummary(
        range: UsageStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageSummary {
        Self.summarize(entries(in: range, now: now, calendar: calendar))
    }

    /// One row per provider+model with entries in the range, longest audio first,
    /// ties broken by provider then model. Each row applies the cost rule on its own.
    public func breakdown(
        range: UsageStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageBreakdownRow] {
        let grouped = Dictionary(grouping: entries(in: range, now: now, calendar: calendar)) { entry in
            ProviderModelKey(providerID: entry.providerID, modelID: entry.modelID)
        }
        return grouped
            .map { key, entries in UsageBreakdownRow(key: key, summary: Self.summarize(entries)) }
            .sorted { lhs, rhs in
                if lhs.summary.audioDurationSeconds != rhs.summary.audioDurationSeconds {
                    return lhs.summary.audioDurationSeconds > rhs.summary.audioDurationSeconds
                }
                if lhs.key.providerID != rhs.key.providerID {
                    return lhs.key.providerID < rhs.key.providerID
                }
                return lhs.key.modelID < rhs.key.modelID
            }
    }

    /// Removes the entries for `keys` that this instance has seen. An entry the other app
    /// added since then stays: nobody looked at it before asking for the reset.
    public func resetCounters(for keys: Set<ProviderModelKey>) {
        guard !keys.isEmpty else { return }
        let targeted = Set(entries.filter { keys.contains(Self.key(of: $0)) }.map(\.id))
        guard !targeted.isEmpty else { return }
        removeFromFile(targeted)
    }

    /// Removes every entry this instance has seen, and nothing the other app added since.
    public func resetAll() {
        guard !entries.isEmpty else { return }
        removeFromFile(Set(entries.map(\.id)))
    }

    // MARK: - Internals

    private func filteredEntries(
        providerID: String,
        modelID: String,
        range: UsageStatsRange,
        now: Date,
        calendar: Calendar
    ) -> [UsageEntry] {
        entries(in: range, now: now, calendar: calendar).filter { entry in
            entry.providerID == providerID && entry.modelID == modelID
        }
    }

    private func entries(in range: UsageStatsRange, now: Date, calendar: Calendar) -> [UsageEntry] {
        guard let lowerBound = Self.lowerBound(for: range, now: now, calendar: calendar) else {
            return entries
        }
        return entries.filter { $0.createdAt >= lowerBound }
    }

    static func lowerBound(for range: UsageStatsRange, now: Date, calendar: Calendar) -> Date? {
        switch range {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        case .last30Days:
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        case .allTime:
            return nil
        }
    }

    static func summarize(_ entries: [UsageEntry]) -> UsageSummary {
        guard !entries.isEmpty else { return .empty }

        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        let totalDuration = entries.reduce(0.0) { $0 + $1.audioDurationSeconds }

        let pricedEntries = entries.filter { $0.estimatedPriceAtTime != nil }
        let currencies = Set(pricedEntries.compactMap(\.currency))

        let hasCompleteCost = pricedEntries.count == entries.count
        let hasSingleCurrency = currencies.count == 1
        let canSumCosts = hasCompleteCost && hasSingleCurrency

        let estimatedCost: Double? = canSumCosts
            ? pricedEntries.reduce(0) { $0 + ($1.estimatedPriceAtTime ?? 0) }
            : nil
        let currency: String? = canSumCosts ? currencies.first : nil

        return UsageSummary(
            wordCount: totalWords,
            audioDurationSeconds: totalDuration,
            estimatedCost: estimatedCost,
            currency: currency
        )
    }

    private func removeFromFile(_ ids: Set<UUID>) {
        do {
            try file.update { contents in contents.removeAll { ids.contains($0.id) } }
            publish(file.contents)
        } catch {
            // Non-fatal: the file is left as it was, and so is the list.
        }
    }

    private func publish(_ fresh: [UsageEntry]) {
        if fresh != entries {
            entries = fresh
        }
    }

    private static func key(of entry: UsageEntry) -> ProviderModelKey {
        ProviderModelKey(providerID: entry.providerID, modelID: entry.modelID)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
        return base.appendingPathComponent("WhisperKey", isDirectory: true).appendingPathComponent("usage-stats.json")
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
