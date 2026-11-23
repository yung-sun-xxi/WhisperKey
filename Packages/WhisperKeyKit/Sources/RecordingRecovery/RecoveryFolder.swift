import AudioEncoder
import AudioRecorder
import Darwin
import Foundation
import HistoryStore
import os

private let recoveryLog = Logger(subsystem: "WhisperKey", category: "RecordingRecovery")

/// What one launch made of the leftover files.
public struct RecoveryReport: Equatable, Sendable {
    /// The recordings that are in history now.
    public var recovered: [UUID] = []
    /// Files with nothing worth a row, or with history turned off.
    public var deleted = 0
    /// Files whose row could not be written.
    public var keptForNextLaunch = 0
    /// Recordings running right now, in the other app.
    public var ownedByLiveProcess = 0

    public init(recovered: [UUID] = [], deleted: Int = 0, keptForNextLaunch: Int = 0, ownedByLiveProcess: Int = 0) {
        self.recovered = recovered
        self.deleted = deleted
        self.keptForNextLaunch = keptForNextLaunch
        self.ownedByLiveProcess = ownedByLiveProcess
    }
}

/// The folder of recovery files, shared by the release and the dev app (#233). It is not
/// `HistoryAudio`: the history store deletes everything there that no row references.
public struct RecoveryFolder: Sendable {
    private static let fileExtension = "wkrecording"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support"))
        return base
            .appendingPathComponent("WhisperKey", isDirectory: true)
            .appendingPathComponent("RecordingRecovery", isDirectory: true)
    }

    public func url(for recordingID: UUID) -> URL {
        directory.appendingPathComponent("\(recordingID.uuidString).\(Self.fileExtension)")
    }

    /// Creates and locks the recording's file, on that file's own queue.
    public func makeFile(_ header: RecoveryHeader) -> RecoveryFile {
        RecoveryFile(url: url(for: header.recordingID), header: header)
    }

    /// The history row of a capture whose stop timed out. Derived from the recording's id,
    /// so the launch that recovers the audio can remove the row that says there was none.
    public static func captureFailureRowID(for recordingID: UUID) -> UUID {
        var bytes = recordingID.uuid
        bytes.15 ^= 0xFF
        return UUID(uuid: bytes)
    }

    /// Turns every leftover file into one pending history row and deletes it.
    ///
    /// A file another process holds is a running recording and is left alone. A row that
    /// cannot be written leaves its file for the next launch. Oldest first, so a history
    /// too small for all of them keeps the newest.
    public func recover(into history: HistoryStore) -> RecoveryReport {
        var report = RecoveryReport()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let urls = names
            .filter { ($0 as NSString).pathExtension == Self.fileExtension }
            .map { directory.appendingPathComponent($0) }
            .sorted { Self.created($0) < Self.created($1) }
        for url in urls {
            let descriptor = Self.openLocked(url)
            guard descriptor >= 0 else {
                if errno == EWOULDBLOCK { report.ownedByLiveProcess += 1 }
                continue
            }
            recoverOpenFile(descriptor: descriptor, at: url, into: history, report: &report)
            close(descriptor)
        }
        if report != RecoveryReport() {
            recoveryLog.notice(
                "launch recovery: recovered=\(report.recovered.count, privacy: .public) deleted=\(report.deleted, privacy: .public) keptForNextLaunch=\(report.keptForNextLaunch, privacy: .public) ownedByLiveProcess=\(report.ownedByLiveProcess, privacy: .public)"
            )
        }
        return report
    }

    /// `descriptor` holds the file's lock.
    func recoverOpenFile(descriptor: Int32, at url: URL, into history: HistoryStore, report: inout RecoveryReport) {
        // The other app had this file, finished with it and deleted it between this
        // process's lookup of the name and its lock.
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_nlink > 0 else { return }

        guard
            history.maxEntries > 0,
            let (header, audio) = Self.read(descriptor),
            audio.duration >= AudioRecorder.minDuration
        else {
            unlink(url.path)
            report.deleted += 1
            return
        }
        guard
            let encoded = try? AudioEncoder().encode(audio),
            history.appendPendingRecognition(
                audioData: encoded.data,
                fileExtension: encoded.fileExtension,
                providerID: header.providerID,
                language: header.language,
                audioDurationSeconds: audio.duration,
                model: header.modelID,
                now: header.startedAt,
                id: header.recordingID,
                inDateOrder: true
            ) != nil
        else {
            recoveryLog.error("recovered recording could not be saved to history; kept for the next launch")
            report.keptForNextLaunch += 1
            return
        }
        _ = history.remove(id: Self.captureFailureRowID(for: header.recordingID))
        unlink(url.path)
        report.recovered.append(header.recordingID)
    }

    // MARK: - Internals

    /// The folder, owner-only, made so if it already existed.
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard mkdir(directory.path, S_IRWXU) == 0 || (errno == EEXIST && chmod(directory.path, S_IRWXU) == 0) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Opens a leftover file and locks it without waiting: -1 with EWOULDBLOCK when another
    /// process holds it.
    private static func openLocked(_ url: URL) -> Int32 {
        open(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    }

    private static func read(_ descriptor: Int32) -> (header: RecoveryHeader, audio: AudioBuffer)? {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return nil }
        return RecoveryFileFormat.decode(data)
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
