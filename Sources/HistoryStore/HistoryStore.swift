import Foundation
import Combine

public enum HistoryEntryStatus: String, Codable, Equatable, Sendable {
    case recognized
    case pendingRecognition
    case noSpeechDetected
}

public enum HistoryAudioError: Error, Equatable {
    case fileUnavailable
}

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public static let assumedTypingWordsPerMinute: Double = 40

    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let provider: String
    public let model: String?
    public let language: String?
    public let audioDurationSeconds: TimeInterval?
    public let wordCount: Int
    public let estimatedPriceAtTime: Double?
    public let currency: String?
    public let destinationUsed: String?
    public let copiedToClipboard: Bool?
    public let autoPasted: Bool?
    public let estimatedSavedSecondsAtTime: TimeInterval?
    public let status: HistoryEntryStatus
    /// Relative file name in the history audio directory. Present only while recognition can be retried.
    public let audioFileName: String?

    public var providerID: String { provider }
    public var hasUsageMetadata: Bool {
        status == .recognized && audioDurationSeconds != nil && estimatedPriceAtTime != nil && currency != nil
    }
    public var canRetryRecognition: Bool { status != .recognized && audioFileName != nil }

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date,
        providerID: String,
        language: String?,
        audioDurationSeconds: TimeInterval? = nil,
        wordCount: Int? = nil,
        model: String? = nil,
        estimatedPriceAtTime: Double? = nil,
        currency: String? = nil,
        destinationUsed: String? = nil,
        copiedToClipboard: Bool? = nil,
        autoPasted: Bool? = nil,
        estimatedSavedSecondsAtTime: TimeInterval? = nil,
        status: HistoryEntryStatus = .recognized,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.provider = providerID
        self.model = model
        self.language = language
        self.audioDurationSeconds = audioDurationSeconds
        self.wordCount = wordCount ?? Self.countWords(in: text)
        self.estimatedPriceAtTime = estimatedPriceAtTime
        self.currency = currency
        self.destinationUsed = destinationUsed
        self.copiedToClipboard = copiedToClipboard
        self.autoPasted = autoPasted
        self.estimatedSavedSecondsAtTime = estimatedSavedSecondsAtTime
            ?? Self.estimatedSavedSeconds(wordCount: self.wordCount, audioDurationSeconds: audioDurationSeconds)
        self.status = status
        self.audioFileName = audioFileName
    }

    public func preview(maxLength: Int = 100) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > maxLength else { return oneLine }
        let prefix = oneLine.prefix(maxLength).trimmingCharacters(in: .whitespaces)
        return prefix + "…"
    }

    public static func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    public static func estimatedSavedSeconds(wordCount: Int, audioDurationSeconds: TimeInterval?) -> TimeInterval {
        guard wordCount > 0 else { return 0 }
        let typingSeconds = Double(wordCount) / assumedTypingWordsPerMinute * 60
        let dictatedSeconds = max(audioDurationSeconds ?? 0, 0)
        return max(typingSeconds - dictatedSeconds, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case provider
        case providerID
        case model
        case language
        case audioDurationSeconds
        case wordCount
        case estimatedPriceAtTime
        case currency
        case destinationUsed
        case copiedToClipboard
        case autoPasted
        case estimatedSavedSecondsAtTime
        case status
        case audioFileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        let wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? Self.countWords(in: text)
        let audioDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .audioDurationSeconds)

        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = text
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider)
            ?? container.decode(String.self, forKey: .providerID)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.audioDurationSeconds = audioDurationSeconds
        self.wordCount = wordCount
        self.estimatedPriceAtTime = try container.decodeIfPresent(Double.self, forKey: .estimatedPriceAtTime)
        self.currency = try container.decodeIfPresent(String.self, forKey: .currency)
        self.destinationUsed = try container.decodeIfPresent(String.self, forKey: .destinationUsed)
        self.copiedToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copiedToClipboard)
        self.autoPasted = try container.decodeIfPresent(Bool.self, forKey: .autoPasted)
        self.estimatedSavedSecondsAtTime = try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedSavedSecondsAtTime)
            ?? Self.estimatedSavedSeconds(wordCount: wordCount, audioDurationSeconds: audioDurationSeconds)
        self.status = try container.decodeIfPresent(HistoryEntryStatus.self, forKey: .status) ?? .recognized
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encodeIfPresent(estimatedPriceAtTime, forKey: .estimatedPriceAtTime)
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(destinationUsed, forKey: .destinationUsed)
        try container.encodeIfPresent(copiedToClipboard, forKey: .copiedToClipboard)
        try container.encodeIfPresent(autoPasted, forKey: .autoPasted)
        try container.encodeIfPresent(estimatedSavedSecondsAtTime, forKey: .estimatedSavedSecondsAtTime)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
    }
}

public struct TranscriptionCostEstimate: Equatable, Sendable {
    public let amount: Double
    public let currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

public enum TranscriptionCostEstimator {
    public static func estimate(
        providerID: String,
        model: String,
        audioDurationSeconds: TimeInterval
    ) -> TranscriptionCostEstimate? {
        guard audioDurationSeconds > 0 else {
            return TranscriptionCostEstimate(amount: 0, currency: "USD")
        }

        switch providerID {
        case "openai":
            return estimateOpenAI(model: model, audioDurationSeconds: audioDurationSeconds)
        case "groq":
            return estimateGroq(model: model, audioDurationSeconds: audioDurationSeconds)
        default:
            return nil
        }
    }

    private static func estimateOpenAI(model: String, audioDurationSeconds: TimeInterval) -> TranscriptionCostEstimate? {
        let dollarsPerMinute: Double
        switch model {
        case "whisper-1":
            dollarsPerMinute = 0.006
        case "gpt-4o-transcribe":
            dollarsPerMinute = 0.006
        case "gpt-4o-mini-transcribe":
            dollarsPerMinute = 0.003
        default:
            return nil
        }

        return TranscriptionCostEstimate(
            amount: audioDurationSeconds / 60 * dollarsPerMinute,
            currency: "USD"
        )
    }

    private static func estimateGroq(model: String, audioDurationSeconds: TimeInterval) -> TranscriptionCostEstimate? {
        let dollarsPerHour: Double
        switch model {
        case "whisper-large-v3":
            dollarsPerHour = 0.111
        case "whisper-large-v3-turbo":
            dollarsPerHour = 0.04
        case "distil-whisper-large-v3-en":
            dollarsPerHour = 0.02
        default:
            return nil
        }

        let billableSeconds = max(audioDurationSeconds, 10)
        return TranscriptionCostEstimate(
            amount: billableSeconds / 3_600 * dollarsPerHour,
            currency: "USD"
        )
    }
}

public struct HistoryUsageSummary: Equatable, Sendable {
    public let audioDurationSeconds: TimeInterval
    public let wordCount: Int
    public let estimatedCost: Double?
    public let currency: String?
    public let estimatedSavedSeconds: TimeInterval

    public init(
        audioDurationSeconds: TimeInterval,
        wordCount: Int,
        estimatedCost: Double?,
        currency: String?,
        estimatedSavedSeconds: TimeInterval
    ) {
        self.audioDurationSeconds = audioDurationSeconds
        self.wordCount = wordCount
        self.estimatedCost = estimatedCost
        self.currency = currency
        self.estimatedSavedSeconds = estimatedSavedSeconds
    }

    public static func today(
        from entries: [HistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HistoryUsageSummary {
        let todaysEntries = entries.filter {
            calendar.isDate($0.createdAt, inSameDayAs: now) && $0.hasUsageMetadata
        }
        let totalDuration = todaysEntries.reduce(0) { $0 + max($1.audioDurationSeconds ?? 0, 0) }
        let totalWords = todaysEntries.reduce(0) { $0 + $1.wordCount }
        let totalSaved = todaysEntries.reduce(0) { $0 + max($1.estimatedSavedSecondsAtTime ?? 0, 0) }

        let pricedEntries = todaysEntries.filter { $0.estimatedPriceAtTime != nil }
        let hasCompleteCost = pricedEntries.count == todaysEntries.count
        let currencies = Set(pricedEntries.compactMap(\.currency))
        let hasSingleCurrency = currencies.count == 1 || todaysEntries.isEmpty
        let currency = todaysEntries.isEmpty ? "USD" : (hasCompleteCost && hasSingleCurrency ? currencies.first : nil)
        let estimatedCost = todaysEntries.isEmpty
            ? 0
            : (hasCompleteCost && hasSingleCurrency ? pricedEntries.reduce(0) { $0 + ($1.estimatedPriceAtTime ?? 0) } : nil)

        return HistoryUsageSummary(
            audioDurationSeconds: totalDuration,
            wordCount: totalWords,
            estimatedCost: estimatedCost,
            currency: currency,
            estimatedSavedSeconds: totalSaved
        )
    }
}

public final class HistoryStore: ObservableObject, @unchecked Sendable {

    public static let defaultMaxEntries = 30
    public static let allowedMaxRange: ClosedRange<Int> = 0...1000

    @Published public private(set) var entries: [HistoryEntry] = []
    public private(set) var maxEntries: Int

    private let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil, maxEntries: Int = HistoryStore.defaultMaxEntries) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.maxEntries = Self.clamp(maxEntries)

        let loaded = (try? Self.load(from: resolvedURL)) ?? []
        let trimmed = Self.applyMax(entries: loaded, max: self.maxEntries)
        self.entries = trimmed
        if trimmed.count != loaded.count {
            try? Self.persist(entries: trimmed, to: resolvedURL)
        }
        removeOrphanedAudio()
    }

    @discardableResult
    public func append(
        text: String,
        providerID: String,
        language: String?,
        now: Date = Date(),
        id: UUID = UUID(),
        audioDurationSeconds: TimeInterval? = nil,
        model: String? = nil,
        estimatedPriceAtTime: Double? = nil,
        currency: String? = nil,
        destinationUsed: String? = nil,
        copiedToClipboard: Bool? = nil,
        autoPasted: Bool? = nil
    ) -> HistoryEntry? {
        guard maxEntries > 0 else { return nil }
        let entry = HistoryEntry(
            id: id,
            text: text,
            createdAt: now,
            providerID: providerID,
            language: language,
            audioDurationSeconds: audioDurationSeconds,
            model: model,
            estimatedPriceAtTime: estimatedPriceAtTime,
            currency: currency,
            destinationUsed: destinationUsed,
            copiedToClipboard: copiedToClipboard,
            autoPasted: autoPasted
        )
        let updated = Self.applyMax(entries: [entry] + entries, max: maxEntries)
        applyAndPersist(updated)
        return entry
    }

    @discardableResult
    public func appendPendingRecognition(
        audioData: Data,
        fileExtension: String,
        providerID: String,
        language: String?,
        audioDurationSeconds: TimeInterval,
        model: String?,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> HistoryEntry? {
        guard maxEntries > 0, !audioData.isEmpty else { return nil }

        let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExtension.isEmpty,
              normalizedExtension.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }

        let fileName = "\(id.uuidString).\(normalizedExtension.lowercased())"
        let entry = HistoryEntry(
            id: id,
            text: "",
            createdAt: now,
            providerID: providerID,
            language: language,
            audioDurationSeconds: audioDurationSeconds,
            wordCount: 0,
            model: model,
            status: .pendingRecognition,
            audioFileName: fileName
        )

        do {
            try writeAudio(audioData, fileName: fileName)
        } catch {
            return nil
        }

        let updated = Self.applyMax(entries: [entry] + entries, max: maxEntries)
        guard applyAndPersist(updated) else {
            removeAudio(fileName: fileName)
            return nil
        }
        return entry
    }

    @discardableResult
    public func markRecognized(
        id: UUID,
        text: String,
        providerID: String,
        language: String?,
        model: String?,
        estimatedPriceAtTime: Double?,
        currency: String?,
        destinationUsed: String?,
        copiedToClipboard: Bool?,
        autoPasted: Bool?
    ) -> HistoryEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = entries[index]
        let updatedEntry = HistoryEntry(
            id: existing.id,
            text: text,
            createdAt: existing.createdAt,
            providerID: providerID,
            language: language,
            audioDurationSeconds: existing.audioDurationSeconds,
            wordCount: HistoryEntry.countWords(in: text),
            model: model,
            estimatedPriceAtTime: estimatedPriceAtTime,
            currency: currency,
            destinationUsed: destinationUsed,
            copiedToClipboard: copiedToClipboard,
            autoPasted: autoPasted,
            status: .recognized
        )
        var updated = entries
        updated[index] = updatedEntry
        guard applyAndPersist(updated) else { return nil }
        return updatedEntry
    }

    @discardableResult
    public func markNoSpeechDetected(id: UUID) -> HistoryEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = entries[index]
        let updatedEntry = HistoryEntry(
            id: existing.id,
            text: "",
            createdAt: existing.createdAt,
            providerID: existing.providerID,
            language: existing.language,
            audioDurationSeconds: existing.audioDurationSeconds,
            wordCount: 0,
            model: existing.model,
            status: .noSpeechDetected,
            audioFileName: existing.audioFileName
        )
        var updated = entries
        updated[index] = updatedEntry
        guard applyAndPersist(updated) else { return nil }
        return updatedEntry
    }

    public func audioData(for entry: HistoryEntry) throws -> Data {
        guard let fileName = entry.audioFileName else { throw HistoryAudioError.fileUnavailable }
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw HistoryAudioError.fileUnavailable }
        return try Data(contentsOf: fileURL)
    }

    public func hasAudio(for entry: HistoryEntry) -> Bool {
        guard let fileName = entry.audioFileName else { return false }
        return FileManager.default.fileExists(atPath: audioDirectory.appendingPathComponent(fileName).path)
    }

    public func usageSummaryForToday(now: Date = Date(), calendar: Calendar = .current) -> HistoryUsageSummary {
        HistoryUsageSummary.today(from: entries, now: now, calendar: calendar)
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        _ = applyAndPersist([])
    }

    public func setMaxEntries(_ value: Int) {
        let clamped = Self.clamp(value)
        guard clamped != maxEntries else { return }
        maxEntries = clamped
        let trimmed = Self.applyMax(entries: entries, max: clamped)
        if trimmed.count != entries.count {
            _ = applyAndPersist(trimmed)
        }
    }

    public var fileURL: URL { url }
    public var audioDirectoryURL: URL { audioDirectory }

    // MARK: - Internals

    @discardableResult
    private func applyAndPersist(_ updated: [HistoryEntry]) -> Bool {
        do {
            try Self.persist(entries: updated, to: url)
            let retainedAudio = Set(updated.compactMap(\.audioFileName))
            let removedAudio = entries.compactMap(\.audioFileName).filter { !retainedAudio.contains($0) }
            entries = updated
            removedAudio.forEach(removeAudio(fileName:))
            return true
        } catch {
            // Persistence failure is non-fatal — surface via the UI in a future toast.
            return false
        }
    }

    private var audioDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("HistoryAudio", isDirectory: true)
    }

    private func writeAudio(_ data: Data, fileName: String) throws {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try data.write(to: audioDirectory.appendingPathComponent(fileName), options: [.atomic])
    }

    private func removeAudio(fileName: String) {
        try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(fileName))
    }

    private func removeOrphanedAudio() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let referenced = Set(entries.compactMap(\.audioFileName))
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, allowedMaxRange.lowerBound), allowedMaxRange.upperBound)
    }

    static func applyMax(entries: [HistoryEntry], max: Int) -> [HistoryEntry] {
        if max <= 0 { return [] }
        if entries.count <= max { return entries }
        return Array(entries.prefix(max))
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
        return base.appendingPathComponent("WhisperKey", isDirectory: true).appendingPathComponent("history.json")
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

    static func load(from url: URL) throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try makeDecoder().decode([HistoryEntry].self, from: data)
    }

    static func persist(entries: [HistoryEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try makeEncoder().encode(entries)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).json.tmp")
        try data.write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
