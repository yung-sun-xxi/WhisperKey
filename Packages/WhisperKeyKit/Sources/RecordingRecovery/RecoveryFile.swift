import Darwin
import Foundation
import os

private let recoveryLog = Logger(subsystem: "WhisperKey", category: "RecordingRecovery")

/// The disk calls, so a test can make the disk full, slow or broken.
struct RecoveryFileIO: Sendable {
    var write: @Sendable (Int32, UnsafeRawBufferPointer) -> Int
    var syncToDevice: @Sendable (Int32) -> Bool

    static let system = RecoveryFileIO(
        write: { Darwin.write($0, $1.baseAddress, $1.count) },
        // `fsync` stops at the drive's cache; only F_FULLFSYNC survives a power loss. Volumes
        // without it get what `fsync` gives.
        syncToDevice: { fcntl($0, F_FULLFSYNC) == 0 || fsync($0) == 0 }
    )
}

/// The recovery file of one recording that is still running (#233).
///
/// Every disk call is made on this file's own serial utility queue, so nothing here can
/// hold up the capture: `append` only queues. The one exception is `discard`, which unlinks
/// before it returns, because an exit right after it would never run a queued deletion.
///
/// Ownership is a lock the kernel drops with the process, SIGKILL included. The file is
/// created and locked by one `open`, so no other process ever sees it unlocked while this
/// recording lives; O_CLOEXEC keeps the lock out of child processes.
///
/// Any failure is logged once, stops the writing, and leaves what is on disk. The recording
/// never hears of it.
public final class RecoveryFile: @unchecked Sendable {
    private let url: URL
    private let header: Data
    private let io: RecoveryFileIO
    private let syncIntervalNanos: UInt64
    private let queue: DispatchQueue

    private let lock = NSLock()
    // Guarded by `lock`.
    private var isDiscarded = false
    private var isCreated = false

    // Touched only on `queue`.
    private var descriptor: Int32 = -1
    private var isStopped = false
    private var lastSyncNanos: UInt64 = 0

    private static let openAttempts = 5
    private static let openRetryDelay: useconds_t = 20_000

    init(url: URL, header: RecoveryHeader, io: RecoveryFileIO = .system, syncInterval: TimeInterval = 1) {
        self.url = url
        self.header = RecoveryFileFormat.encode(header)
        self.io = io
        self.syncIntervalNanos = UInt64(syncInterval * 1_000_000_000)
        queue = DispatchQueue(label: "WhisperKey.RecordingRecovery", qos: .utility)
        queue.async { [self] in create() }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Queues a chunk of the recording's audio.
    public func append(_ pcm: Data) {
        queue.async { [self] in
            guard !isStopped, descriptor >= 0 else { return }
            guard write(pcm) else { return }
            syncIfDue()
        }
    }

    /// The recording needs no file any more. Gone by the time this returns; nothing queued
    /// earlier brings it back.
    public func discard() {
        lock.lock()
        isDiscarded = true
        if isCreated { unlink(url.path) }
        lock.unlock()
        queue.async { [self] in finish() }
    }

    /// Nothing more to write: writes what is queued, then lets go of the file so the next
    /// launch can recover it.
    public func keep() {
        queue.async { [self] in finish() }
    }

    /// Waits until everything queued so far has reached the disk or failed.
    public func drain() {
        queue.sync {}
    }

    // MARK: - On the queue

    private func create() {
        do {
            try RecoveryFolder.prepare(url.deletingLastPathComponent())
        } catch {
            return stop("folder could not be prepared", error: Int32(truncatingIfNeeded: (error as NSError).code))
        }
        for attempt in 1...Self.openAttempts {
            lock.lock()
            guard !isDiscarded else {
                lock.unlock()
                isStopped = true
                return
            }
            descriptor = open(
                url.path,
                O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            let failure = errno
            isCreated = descriptor >= 0
            lock.unlock()
            if descriptor >= 0 { break }
            // A launching app locked the new file between its creation and its lock, found
            // it empty and is deleting it: try again.
            guard failure == EWOULDBLOCK || failure == EEXIST, attempt < Self.openAttempts else {
                return stop("file could not be created", error: failure)
            }
            usleep(Self.openRetryDelay)
        }
        lastSyncNanos = DispatchTime.now().uptimeNanoseconds
        _ = write(header)
    }

    private func write(_ data: Data) -> Bool {
        var failure: Int32 = 0
        let written = data.withUnsafeBytes { buffer -> Bool in
            var rest = buffer[...]
            while !rest.isEmpty {
                let count = io.write(descriptor, UnsafeRawBufferPointer(rebasing: rest))
                if count > 0 {
                    rest = rest.dropFirst(count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    failure = count < 0 ? errno : EIO
                    return false
                }
            }
            return true
        }
        if !written { stop("write failed", error: failure) }
        return written
    }

    private func syncIfDue() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastSyncNanos >= syncIntervalNanos else { return }
        lastSyncNanos = now
        if !io.syncToDevice(descriptor) { stop("sync failed", error: errno) }
    }

    /// The file stays open: its lock still says whose recording this is.
    private func stop(_ what: String, error: Int32) {
        guard !isStopped else { return }
        isStopped = true
        recoveryLog.error("recovery \(what, privacy: .public), errno=\(error, privacy: .public); the recording goes on without it")
    }

    private func finish() {
        isStopped = true
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
}
