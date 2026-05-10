import Foundation
import Combine

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let providerID: String
    public let language: String?

    public init(id: UUID = UUID(), text: String, createdAt: Date, providerID: String, language: String?) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.providerID = providerID
        self.language = language
    }

    public func preview(maxLength: Int = 100) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > maxLength else { return oneLine }
        let prefix = oneLine.prefix(maxLength).trimmingCharacters(in: .whitespaces)
        return prefix + "…"
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
    }

    @discardableResult
    public func append(text: String, providerID: String, language: String?, now: Date = Date(), id: UUID = UUID()) -> HistoryEntry? {
        guard maxEntries > 0 else { return nil }
        let entry = HistoryEntry(id: id, text: text, createdAt: now, providerID: providerID, language: language)
        let updated = Self.applyMax(entries: [entry] + entries, max: maxEntries)
        applyAndPersist(updated)
        return entry
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        applyAndPersist([])
    }

    public func setMaxEntries(_ value: Int) {
        let clamped = Self.clamp(value)
        guard clamped != maxEntries else { return }
        maxEntries = clamped
        let trimmed = Self.applyMax(entries: entries, max: clamped)
        if trimmed.count != entries.count {
            applyAndPersist(trimmed)
        }
    }

    public var fileURL: URL { url }

    // MARK: - Internals

    private func applyAndPersist(_ updated: [HistoryEntry]) {
        entries = updated
        do {
            try Self.persist(entries: updated, to: url)
        } catch {
            // Persistence failure is non-fatal — surface via the UI in a future toast.
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
