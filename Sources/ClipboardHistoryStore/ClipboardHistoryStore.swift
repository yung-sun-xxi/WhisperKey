import Combine
import Foundation
import SharedJSONFile

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

    /// Newest first: the file merged with this instance's concealed entries, each text
    /// once, cut to `maxEntries`.
    @Published public private(set) var entries: [ClipboardEntry] = []
    public private(set) var maxEntries: Int

    private let url: URL
    private let file: SharedJSONFile<ClipboardEntry>
    private var watcher: DirectoryWatcher?
    /// Concealed entries this instance recorded, newest first. Memory only, never the file,
    /// and never seen by the other app.
    private var concealed: [ConcealedEntry] = []

    /// A concealed entry and the file entries that were already there when it was recorded.
    /// Everything else in the file is newer than it. Dates cannot decide this: the file
    /// keeps them to the whole second.
    struct ConcealedEntry {
        let entry: ClipboardEntry
        let olderIDs: Set<UUID>
    }

    /// The file is shared with the other build of the app (release and dev), which may run
    /// at the same time with a different cap (#140). Every change reads the file as it is now
    /// and writes it back under a lock, the directory is watched for the other app's
    /// writes, and an ordinary write never shrinks the file below the size it had, except
    /// by the duplicates it removes. Loading does not trim the file; only lowering the cap
    /// with `setMaxEntries` does.
    ///
    /// Loading does collapse duplicates once: builds before #211 stored a text again every
    /// time it came back, and a file they filled keeps the newest entry of each text.
    public init(url: URL? = nil, maxEntries: Int = ClipboardHistoryStore.defaultMaxEntries) {
        let resolvedURL = url ?? Self.defaultURL()
        self.url = resolvedURL
        self.maxEntries = Self.clamp(maxEntries)
        self.file = SharedJSONFile(url: resolvedURL, encoder: Self.makeEncoder(), decoder: Self.makeDecoder())

        try? FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: true)
        // Watch before the first read, so a write landing between the two is not missed.
        self.watcher = DirectoryWatcher(directory: file.directory) { [weak self] in
            self?.reloadFromDisk()
        }
        // One locked step; a file without duplicates is read and not written.
        _ = try? updateFile { contents in contents = Self.deduplicated(contents) }
        refreshDisplay()
    }

    /// Picks up another process's writes. The directory watcher calls this on the main
    /// queue; `entries` is republished only when what it shows actually changed.
    public func reloadFromDisk() {
        guard (try? file.reloadIfChanged()) != nil else { return }
        refreshDisplay()
    }

    /// Offers a candidate entry. Returns the entry that was stored, or `nil` when it was
    /// rejected as whitespace-only or because the cap is zero.
    ///
    /// One text, one entry (#211). A text that is already anywhere in the list — the file
    /// as it is now, or this instance's concealed entries — is not stored a second time:
    /// every older entry with it is removed and the new one goes on top, with the new
    /// time, origin and concealment. That holds for a repeat of the newest entry too, so
    /// one copy caught by both apps lands in the file once.
    ///
    /// The entry on top is always a new entry with a new id, never the old one moved. A
    /// concealed entry finds its place by the ids of the file entries that were there
    /// before it (`ConcealedEntry.olderIDs`); a moved entry that kept its id would still
    /// count as older than a password copied before the move.
    ///
    /// `isConcealed` changes nothing about whether the entry is kept, where it sits, how
    /// it de-duplicates or whether it counts against the cap. It changes only whether it
    /// is written to the file — and so a concealed copy of a text that sits in the file
    /// takes it out of the file, and an ordinary copy of a text held concealed is written.
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

        let entry = ClipboardEntry(id: id, text: text, capturedAt: now, origin: origin, isConcealed: isConcealed)
        defer { refreshDisplay() }

        if isConcealed {
            // The entry itself is never written, but the same text in the file has to go,
            // and what is older than this entry is the file as that leaves it.
            _ = try? updateFile { contents in contents.removeAll { $0.text == text } }
            concealed.removeAll { $0.entry.text == text }
            concealed.insert(ConcealedEntry(entry: entry, olderIDs: Set(file.contents.map(\.id))), at: 0)
            return entry
        }

        let stored: Void? = try? updateFile { contents in
            let previousCount = contents.count
            contents.removeAll { $0.text == text }
            contents.insert(entry, at: 0)
            // Counted before the duplicates went, so replacing one never trims another.
            let keep = max(self.maxEntries, previousCount)
            if contents.count > keep {
                contents = Array(contents.prefix(keep))
            }
        }
        guard stored != nil else { return nil }
        concealed.removeAll { $0.entry.text == text }
        return entry
    }

    /// Empties the list: every entry this instance has seen in the file, beyond its own cap
    /// too, and its concealed entries. Nothing the other app added since is touched.
    public func clear() {
        let seen = Set(file.contents.map(\.id))
        concealed = []
        if !seen.isEmpty {
            _ = try? updateFile { contents in contents.removeAll { seen.contains($0.id) } }
        }
        refreshDisplay()
    }

    /// Raising the cap only shows more of the file. Lowering it trims the shared file to
    /// the new cap.
    public func setMaxEntries(_ value: Int) {
        let clamped = Self.clamp(value)
        guard clamped != maxEntries else { return }
        let lowered = clamped < maxEntries
        maxEntries = clamped
        if lowered {
            _ = try? updateFile { contents in
                if contents.count > clamped { contents = Array(contents.prefix(clamped)) }
            }
        }
        refreshDisplay()
    }

    public var fileURL: URL { url }

    // MARK: - Internals

    /// Every write of the file goes through here, and so through `persistable(_:)`.
    private func updateFile<Result>(_ change: (inout [ClipboardEntry]) throws -> Result) throws -> Result {
        try file.update { contents -> Result in
            let result = try change(&contents)
            contents = Self.persistable(contents)
            return result
        }
    }

    /// Shows the newest `maxEntries` of the file and this instance's concealed entries
    /// together. A concealed entry pushed out of that window is forgotten, exactly as it
    /// was when the list was only ever in memory.
    ///
    /// Each text is shown once, the newest of it. `record` keeps the file that way, but
    /// the other build of the app shares the file and may not: showing is where that is
    /// absorbed, without writing. A concealed entry hidden behind a newer entry with its
    /// text is forgotten like one pushed out of the window.
    private func refreshDisplay() {
        let shown = maxEntries > 0
            ? Array(Self.deduplicated(Self.merge(persisted: file.contents, concealed: concealed)).prefix(maxEntries))
            : []
        let shownIDs = Set(shown.map(\.id))
        concealed.removeAll { !shownIDs.contains($0.entry.id) }
        if shown != entries {
            entries = shown
        }
    }

    /// The file's entries with the concealed ones put back where they were recorded: each
    /// sits above the file entries that were there before it and below every later one.
    /// Both lists and the result are newest first.
    static func merge(persisted: [ClipboardEntry], concealed: [ConcealedEntry]) -> [ClipboardEntry] {
        guard !concealed.isEmpty else { return persisted }
        // Later file entries are always inserted on top, so the ones newer than a concealed
        // entry are a prefix of the file, and it goes right after that prefix.
        var above: [Int: [ClipboardEntry]] = [:]
        for item in concealed {
            let index = persisted.firstIndex { item.olderIDs.contains($0.id) } ?? persisted.count
            above[index, default: []].append(item.entry)
        }
        var merged: [ClipboardEntry] = []
        merged.reserveCapacity(persisted.count + concealed.count)
        for (index, entry) in persisted.enumerated() {
            merged.append(contentsOf: above[index] ?? [])
            merged.append(entry)
        }
        merged.append(contentsOf: above[persisted.count] ?? [])
        return merged
    }

    /// The newest entry of each text, in the order given (newest first). Text is compared
    /// verbatim.
    static func deduplicated(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.text).inserted }
    }

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
}
