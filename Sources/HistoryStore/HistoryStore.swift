import Foundation
import Combine
import SharedJSONFile

public enum HistoryEntryStatus: String, Codable, Equatable, Sendable {
    case recognized
    case pendingRecognition
    case noSpeechDetected
    case silentAudio
    case captureFailed
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
    public var canRetryRecognition: Bool {
        switch status {
        case .pendingRecognition, .noSpeechDetected:
            audioFileName != nil
        case .recognized, .silentAudio, .captureFailed:
            false
        }
    }

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
        case "gpt-transcribe":
            dollarsPerMinute = 0.0045
        case "whisper-1":
            // No longer offered; kept so older history entries still show a cost.
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
            // No longer offered; kept so older history entries still show a cost.
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

/// The transcription journal, in `history.json` and its `HistoryAudio` folder.
///
/// The file is shared with the other build of the app (release and dev), which may run at
/// the same time with a different cap (#140). So:
/// - every change reads the file as it is now and writes it back under a lock
///   (`SharedJSONFile`), and the directory is watched for the other app's writes;
/// - `entries` shows only the newest `maxEntries` of the file, but an ordinary write never
///   shrinks the file below the size it had, so a small cap here does not cut a long
///   history kept by the other app. Only lowering the cap with `setMaxEntries` trims it.
public final class HistoryStore: ObservableObject, @unchecked Sendable {

    public static let defaultMaxEntries = 30
    public static let allowedMaxRange: ClosedRange<Int> = 0...1000

    /// Newest first: the first `maxEntries` entries of the file.
    @Published public private(set) var entries: [HistoryEntry] = []
    public private(set) var maxEntries: Int

    private let url: URL
    private let file: SharedJSONFile<HistoryEntry>
    private var watcher: DirectoryWatcher?

    public init(url: URL? = nil, maxEntries: Int = HistoryStore.defaultMaxEntries) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.maxEntries = Self.clamp(maxEntries)
        self.file = SharedJSONFile(url: resolvedURL, encoder: Self.makeEncoder(), decoder: Self.makeDecoder())

        try? FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        // Watch before the first read, so a write landing between the two is not missed.
        self.watcher = DirectoryWatcher(directory: file.directory) { [weak self] in
            self?.reloadFromDisk()
        }
        // Loading does not trim the file. The orphan sweep runs under the lock and counts
        // as referenced every entry in the file, including the ones beyond this cap that
        // the other app still shows.
        _ = try? file.update { contents in self.removeOrphanedAudio(referencedBy: contents) }
        refreshDisplay()
    }

    /// Picks up another process's writes. The directory watcher calls this on the main
    /// queue; `entries` is republished only when what it shows actually changed.
    public func reloadFromDisk() {
        guard (try? file.reloadIfChanged()) != nil else { return }
        refreshDisplay()
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
        mutate { contents in self.insert(entry, into: &contents) }
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

        // The audio is written under the same lock as the entry, so the other app's orphan
        // sweep never sees the file without the entry that references it.
        var audioWritten = false
        let written: Void? = mutate { contents in
            try self.writeAudio(audioData, fileName: fileName)
            audioWritten = true
            self.insert(entry, into: &contents)
        }
        guard written != nil else {
            if audioWritten { removeAudio(fileName: fileName) }
            return nil
        }
        return entry
    }

    /// Records a failed microphone capture when no audio was available to save or retry.
    @discardableResult
    public func appendCaptureFailed(
        providerID: String,
        language: String?,
        model: String?,
        message: String,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> HistoryEntry? {
        guard maxEntries > 0 else { return nil }
        let entry = HistoryEntry(
            id: id,
            text: message,
            createdAt: now,
            providerID: providerID,
            language: language,
            wordCount: 0,
            model: model,
            status: .captureFailed
        )
        guard mutate({ contents in self.insert(entry, into: &contents) }) != nil else { return nil }
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
        replace(id: id) { existing in
            HistoryEntry(
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
        }
    }

    @discardableResult
    public func markNoSpeechDetected(id: UUID) -> HistoryEntry? {
        replace(id: id) { existing in
            HistoryEntry(
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
        }
    }

    @discardableResult
    public func markSilentAudio(id: UUID) -> HistoryEntry? {
        replace(id: id) { existing in
            HistoryEntry(
                id: existing.id,
                text: "",
                createdAt: existing.createdAt,
                providerID: existing.providerID,
                language: existing.language,
                audioDurationSeconds: existing.audioDurationSeconds,
                wordCount: 0,
                model: existing.model,
                status: .silentAudio
            )
        }
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

    @discardableResult
    public func remove(id: UUID) -> Bool {
        let removed = mutate { contents -> Bool in
            let before = contents.count
            contents.removeAll { $0.id == id }
            return contents.count != before
        }
        return removed ?? false
    }

    public func usageSummaryForToday(now: Date = Date(), calendar: Calendar = .current) -> HistoryUsageSummary {
        HistoryUsageSummary.today(from: entries, now: now, calendar: calendar)
    }

    /// Removes every entry this instance has seen in the file, beyond its own cap too, and
    /// nothing the other app added since.
    public func clear() {
        let seen = Set(file.contents.map(\.id))
        guard !seen.isEmpty else { return }
        mutate { contents in contents.removeAll { seen.contains($0.id) } }
    }

    /// Raising the cap only shows more of the file. Lowering it is the one operation that
    /// trims the shared file, to the new cap, and deletes the trimmed entries' audio.
    public func setMaxEntries(_ value: Int) {
        let clamped = Self.clamp(value)
        guard clamped != maxEntries else { return }
        let lowered = clamped < maxEntries
        maxEntries = clamped
        if lowered {
            mutate { contents in
                if contents.count > clamped { contents = Array(contents.prefix(clamped)) }
            }
        } else {
            refreshDisplay()
        }
    }

    public var fileURL: URL { url }
    public var audioDirectoryURL: URL { audioDirectory }

    // MARK: - Internals

    /// Puts `entry` on top and drops the oldest down to the larger of this cap and the
    /// size the file had, so an ordinary write never shrinks the file.
    private func insert(_ entry: HistoryEntry, into contents: inout [HistoryEntry]) {
        let previousCount = contents.count
        contents.insert(entry, at: 0)
        let keep = max(maxEntries, previousCount)
        if contents.count > keep {
            contents = Array(contents.prefix(keep))
        }
    }

    private func replace(id: UUID, with make: (HistoryEntry) -> HistoryEntry) -> HistoryEntry? {
        let replaced = mutate { contents -> HistoryEntry? in
            guard let index = contents.firstIndex(where: { $0.id == id }) else { return nil }
            let updated = make(contents[index])
            contents[index] = updated
            return updated
        }
        return replaced ?? nil
    }

    /// Applies `change` to the file as it is now, under the lock, then deletes the audio of
    /// whatever the change dropped and refreshes the list. `nil` means nothing was written.
    @discardableResult
    private func mutate<Result>(_ change: (inout [HistoryEntry]) throws -> Result) -> Result? {
        var droppedAudio: Set<String> = []
        defer { refreshDisplay() }
        do {
            let result = try file.update { contents -> Result in
                let audioBefore = Set(contents.compactMap(\.audioFileName))
                let result = try change(&contents)
                droppedAudio = audioBefore.subtracting(contents.compactMap(\.audioFileName))
                return result
            }
            droppedAudio.forEach(removeAudio(fileName:))
            return result
        } catch {
            // Persistence failure is non-fatal — surface via the UI in a future toast.
            return nil
        }
    }

    private func refreshDisplay() {
        let shown = maxEntries > 0 ? Array(file.contents.prefix(maxEntries)) : []
        if shown != entries {
            entries = shown
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

    /// Must run under the file lock, with `entries` being the whole file.
    private func removeOrphanedAudio(referencedBy entries: [HistoryEntry]) {
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
}
