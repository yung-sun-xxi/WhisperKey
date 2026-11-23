import AudioRecorder
import Foundation
import XCTest
@testable import HistoryStore
@testable import RecordingRecovery

/// Real files in a temp folder laid out as the app's: `history.json`, `HistoryAudio` and
/// `RecordingRecovery` side by side.
class RecoveryTestCase: XCTestCase {
    private(set) var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-RecordingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            chmod(tempDir.path, 0o700)
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    var historyURL: URL { tempDir.appendingPathComponent("history.json") }
    var folder: RecoveryFolder { RecoveryFolder(directory: tempDir.appendingPathComponent("RecordingRecovery", isDirectory: true)) }

    func makeHistory(cap: Int = 30) -> HistoryStore {
        HistoryStore(url: historyURL, maxEntries: cap)
    }

    /// What the file holds, read by a store whose cap shows all of it.
    func rowsOnDisk() -> [HistoryEntry] {
        HistoryStore(url: historyURL, maxEntries: HistoryStore.allowedMaxRange.upperBound).entries
    }

    func makeHeader(_ id: UUID = UUID(), startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> RecoveryHeader {
        RecoveryHeader(
            recordingID: id,
            startedAt: startedAt,
            sampleRate: 16_000,
            channelCount: 1,
            providerID: "groq",
            modelID: "whisper-large-v3",
            language: "ru"
        )
    }

    /// `seconds` of 16 kHz mono PCM, every sample different from its neighbours.
    func pcm(_ seconds: Double, seed: Int = 0) -> Data {
        let frames = Int((seconds * 16_000).rounded())
        var data = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = Int16(truncatingIfNeeded: (frame + seed) &* 31 &+ 7).littleEndian
            withUnsafeBytes(of: sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A recovery file a dead process left behind.
    func leaveFile(_ header: RecoveryHeader, pcm: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder.directory, withIntermediateDirectories: true)
        let url = folder.url(for: header.recordingID)
        try (RecoveryFileFormat.encode(header) + pcm).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    var recoveryFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.directory.path)) ?? []
    }

    /// The WAV payload of a pending row: what Retry uploads, minus its 44-byte header.
    func samples(of entry: HistoryEntry, in history: HistoryStore) throws -> Data {
        Data(try history.audioData(for: entry).dropFirst(44))
    }

    /// Whether anyone holds the file's lock.
    func isLocked(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == EWOULDBLOCK }
        close(fd)
        return false
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func update(_ change: (inout Value) -> Void) {
        lock.lock(); change(&stored); lock.unlock()
    }
}
