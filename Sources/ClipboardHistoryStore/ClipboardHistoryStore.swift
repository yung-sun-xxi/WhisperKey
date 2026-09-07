import Combine
import Foundation

/// The clipboard history behind the quick-paste popup.
///
/// Deliberately unrelated to `HistoryStore`, which is the transcription journal. The two
/// features meet only through the system clipboard. The persistence shape is copied from
/// `HistoryStore` on purpose: `decodeIfPresent` with a default for every field, atomic
/// file replacement, cap enforced newest-first.
///
/// Recording and persistence are deliberately not the same thing. Everything offered is
/// kept in memory and shown in the popup, concealed items included; only what
/// `persistable(_:)` allows is written to the file. The file is plain JSON at mode 0644
/// in Application Support, so it survives restarts and travels into Time Machine — which
/// is the right home for a copied heading and the wrong one for a copied password.
public final class ClipboardHistoryStore: ObservableObject, @unchecked Sendable {

    public static let defaultMaxEntries = 20
    public static let allowedMaxRange: ClosedRange<Int> = 0...200

    /// Newest first.
    @Published public private(set) var entries: [ClipboardEntry] = []
    public private(set) var maxEntries: Int

    private let url: URL

    public init(url: URL? = nil, maxEntries: Int = ClipboardHistoryStore.defaultMaxEntries) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.maxEntries = Self.clamp(maxEntries)

        let loaded = (try? Self.load(from: resolvedURL)) ?? []
        let trimmed = Self.applyMax(entries: loaded, max: self.maxEntries)
        self.entries = trimmed
        if trimmed.count != loaded.count {
            try? Self.persist(entries: Self.persistable(trimmed), to: resolvedURL)
        }
    }

    /// Offers a candidate entry. Returns the entry that was stored, or `nil` when it was
    /// rejected as whitespace-only, as a repeat of the newest entry, or because the cap
    /// is zero.
    ///
    /// `isConcealed` changes nothing about whether the entry is kept, where it sits, how
    /// it de-duplicates or whether it counts against the cap. It changes only whether it
    /// is written to the file.
    @discardableResult
    public func record(
        text: String,
        origin: ClipboardEntryOrigin,
        isConcealed: Bool = false,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> ClipboardEntry? {
        guard maxEntries > 0 else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Against the most recent entry only. The same text copied again after something
        // else in between is a deliberate second copy and gets its own entry.
        guard entries.first?.text != text else { return nil }

        let entry = ClipboardEntry(id: id, text: text, capturedAt: now, origin: origin, isConcealed: isConcealed)
        let updated = Self.applyMax(entries: [entry] + entries, max: maxEntries)
        entries = updated
        try? Self.persist(entries: Self.persistable(updated), to: url)
        return entry
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        try? Self.persist(entries: [], to: url)
    }

    public func setMaxEntries(_ value: Int) {
        let clamped = Self.clamp(value)
        guard clamped != maxEntries else { return }
        maxEntries = clamped
        let trimmed = Self.applyMax(entries: entries, max: clamped)
        if trimmed.count != entries.count {
            entries = trimmed
            try? Self.persist(entries: Self.persistable(trimmed), to: url)
        }
    }

    public var fileURL: URL { url }

    // MARK: - Internals

    static func clamp(_ value: Int) -> Int {
        min(max(value, allowedMaxRange.lowerBound), allowedMaxRange.upperBound)
    }

    /// The filter that separates what is remembered from what is written.
    ///
    /// It sits on the way *out*, not on the way in: the in-memory list is complete, and
    /// every path that writes the file goes through here. A concealed entry therefore
    /// lives exactly as long as the process does.
    static func persistable(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.filter { !$0.isConcealed }
    }

    static func applyMax(entries: [ClipboardEntry], max: Int) -> [ClipboardEntry] {
        if max <= 0 { return [] }
        if entries.count <= max { return entries }
        return Array(entries.prefix(max))
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
        return base
            .appendingPathComponent("WhisperKey", isDirectory: true)
            .appendingPathComponent("clipboard-history.json")
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

    static func load(from url: URL) throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        return try makeDecoder().decode([ClipboardEntry].self, from: data)
    }

    static func persist(entries: [ClipboardEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try makeEncoder().encode(entries)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".clipboard-history-\(UUID().uuidString).json.tmp")
        try data.write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
