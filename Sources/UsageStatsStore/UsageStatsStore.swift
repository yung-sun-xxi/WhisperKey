import Foundation
import Combine

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

public final class UsageStatsStore: ObservableObject, @unchecked Sendable {
    @Published public private(set) var entries: [UsageEntry] = []

    private let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.entries = (try? Self.load(from: resolvedURL)) ?? []
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
        applyAndPersist(entries + [entry])
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

    public func resetCounters(for keys: Set<ProviderModelKey>) {
        guard !keys.isEmpty else { return }
        let updated = entries.filter { entry in
            !keys.contains(ProviderModelKey(providerID: entry.providerID, modelID: entry.modelID))
        }
        if updated.count != entries.count {
            applyAndPersist(updated)
        }
    }

    public func resetAll() {
        guard !entries.isEmpty else { return }
        applyAndPersist([])
    }

    // MARK: - Internals

    private func filteredEntries(
        providerID: String,
        modelID: String,
        range: UsageStatsRange,
        now: Date,
        calendar: Calendar
    ) -> [UsageEntry] {
        let lowerBound = Self.lowerBound(for: range, now: now, calendar: calendar)
        return entries.filter { entry in
            guard entry.providerID == providerID, entry.modelID == modelID else { return false }
            guard let lowerBound else { return true }
            return entry.createdAt >= lowerBound
        }
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

    private func applyAndPersist(_ updated: [UsageEntry]) {
        entries = updated
        do {
            try Self.persist(entries: updated, to: url)
        } catch {
            // Non-fatal: caller logs separately; usage data is best-effort.
        }
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

    static func load(from url: URL) throws -> [UsageEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try makeDecoder().decode([UsageEntry].self, from: data)
    }

    static func persist(entries: [UsageEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try makeEncoder().encode(entries)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".usage-stats-\(UUID().uuidString).json.tmp")
        try data.write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
