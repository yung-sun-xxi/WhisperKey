import Darwin
import Foundation

/// A JSON array file that more than one process writes.
///
/// The release app and the dev app share their usage, history and clipboard files on
/// purpose. Writing a whole file from an in-memory copy taken at launch makes the second
/// writer erase whatever the first one added (#140). Every change here is therefore one
/// operation under an exclusive lock: take the lock, read the file as it is now, apply the
/// change, write it back atomically, release.
///
/// The lock is `flock` on a sibling file (`.<name>.lock`), never on the data file itself:
/// the data file is replaced on every write, so a lock on it would be a lock on an inode
/// that no longer has a name. `flock` belongs to an open file description, and every
/// operation opens the lock file afresh, so two instances in one process exclude each other
/// exactly as two processes do.
///
/// A file that cannot be read or decoded is never treated as an empty list, because the
/// next write would then erase it. It is renamed aside to `<name>.corrupt-<timestamp>`
/// under the lock, and the operation carries on from empty.
public final class SharedJSONFile<Element: Codable & Equatable> {

    public enum Failure: Error, Equatable {
        case lockUnavailable(errno: Int32)
    }

    public let url: URL

    /// The file's contents as this instance last read or wrote them.
    public private(set) var contents: [Element] = []

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastSignature: Signature?

    public init(url: URL, encoder: JSONEncoder, decoder: JSONDecoder) {
        self.url = url
        self.encoder = encoder
        self.decoder = decoder
    }

    public var lockURL: URL {
        directory.appendingPathComponent(".\(url.lastPathComponent).lock")
    }

    public var directory: URL {
        url.deletingLastPathComponent()
    }

    /// Reads the file under the lock.
    @discardableResult
    public func load() throws -> [Element] {
        try withLock { try loadFresh() }
    }

    /// Reads the file again if it changed on disk since this instance last saw it.
    ///
    /// Returns the new contents only when they differ from `contents`, so a caller that
    /// publishes the result redraws only on a real change. Its own writes, the lock file and
    /// temporary files all touch the directory too, and all come back `nil` here without a
    /// decode.
    public func reloadIfChanged() throws -> [Element]? {
        let current = Signature(of: url)
        if current == lastSignature { return nil }
        let previous = contents
        // No directory means nothing to lock and nothing to read.
        guard FileManager.default.fileExists(atPath: directory.path) else {
            lastSignature = nil
            contents = []
            return previous.isEmpty ? nil : []
        }
        let fresh = try withLock { try loadFresh() }
        return fresh == previous ? nil : fresh
    }

    /// Read, modify and write in one locked step.
    ///
    /// `transform` receives the file's contents as they are now, not this instance's copy.
    /// The file is written only when the transform changed them. If the transform throws,
    /// nothing is written.
    @discardableResult
    public func update<Result>(_ transform: (inout [Element]) throws -> Result) throws -> Result {
        try withLock {
            let before = try loadFresh()
            var after = before
            let result = try transform(&after)
            if after != before {
                try write(after)
            }
            return result
        }
    }

    // MARK: - Internals

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure.lockUnavailable(errno: errno) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.lockUnavailable(errno: errno) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Must be called with the lock held.
    private func loadFresh() throws -> [Element] {
        let fresh: [Element]
        if !FileManager.default.fileExists(atPath: url.path) {
            fresh = []
        } else {
            do {
                let data = try Data(contentsOf: url)
                fresh = data.isEmpty ? [] : try decoder.decode([Element].self, from: data)
            } catch {
                try setAside()
                fresh = []
            }
        }
        contents = fresh
        lastSignature = Signature(of: url)
        return fresh
    }

    /// Must be called with the lock held.
    private func write(_ entries: [Element]) throws {
        let data = try encoder.encode(entries)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        contents = entries
        lastSignature = Signature(of: url)
    }

    /// Must be called with the lock held. Throws when the file cannot be moved, so the
    /// caller writes nothing over it.
    private func setAside() throws {
        let formatter = ISO8601DateFormatter()
        // Basic format, no colons: 20261009T133502Z.
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: Date())
        var destination = directory.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// Enough to tell that the file was replaced or rewritten without reading it. Every
    /// write is an atomic replace, which gives the name a new inode.
    private struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(of url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }
}
