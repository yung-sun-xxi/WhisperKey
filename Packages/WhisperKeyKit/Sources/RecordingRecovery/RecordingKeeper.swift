import AudioEncoder
import AudioRecorder
import Foundation
import HistoryStore

/// What a history row says about the recording besides its audio.
public struct RecordingDetails: Equatable, Sendable {
    public var providerID: String
    public var modelID: String?
    public var language: String?

    public init(providerID: String, modelID: String?, language: String?) {
        self.providerID = providerID
        self.modelID = modelID
        self.language = language
    }
}

/// Gets every recording into history exactly once, and keeps its recovery file for exactly
/// as long as the audio has no row (#233).
///
/// Everything is keyed by the recording's id, which is also its row's id: a stop that timed
/// out can still deliver its audio after the next recording has started.
@MainActor
public final class RecordingKeeper {
    private let history: HistoryStore
    private let folder: RecoveryFolder
    private let encoder = AudioEncoder()

    /// The files this process is writing.
    private var files: [UUID: RecoveryFile] = [:]
    /// Files let go of, for the next launch to recover. Still deletable from here.
    private var keptFiles: [UUID: RecoveryFile] = [:]
    /// Recordings whose audio an exit still has to wait for.
    private var waitingForRow: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(history: HistoryStore, folder: RecoveryFolder) {
        self.history = history
        self.folder = folder
    }

    /// A recording is about to start. Returns where its audio goes while it runs, or nil
    /// when history keeps nothing.
    public func begin(
        _ recordingID: UUID,
        sampleRate: Double,
        channelCount: UInt32,
        details: RecordingDetails
    ) -> CapturedAudioSink? {
        waitingForRow.insert(recordingID)
        guard history.maxEntries > 0 else { return nil }
        let file = folder.makeFile(RecoveryHeader(
            recordingID: recordingID,
            startedAt: Date(),
            sampleRate: sampleRate,
            channelCount: channelCount,
            providerID: details.providerID,
            modelID: details.modelID,
            language: details.language
        ))
        files[recordingID] = file
        return { [file] chunk in file.append(chunk) }
    }

    /// Whether some recording has neither its row nor its answer yet.
    public var isWaitingForRow: Bool { !waitingForRow.isEmpty }

    public func waitForRows() async {
        guard isWaitingForRow else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The recorder stopped.
    @discardableResult
    public func finish(
        _ outcome: AudioRecorderStopOutcome,
        _ recordingID: UUID,
        details: RecordingDetails
    ) throws -> HistoryEntry? {
        switch outcome {
        case .recorded(let buffer):
            return try save(buffer, recordingID, details: details)
        case .tooShort, .noAudio:
            discard(recordingID)
        case .notRecording:
            // Another stop got this recording's audio and settles its file.
            keep(recordingID)
        }
        return nil
    }

    @discardableResult
    public func save(_ buffer: AudioBuffer, _ recordingID: UUID, details: RecordingDetails) throws -> HistoryEntry? {
        let encoded: EncodedAudio
        do {
            encoded = try encoder.encode(buffer)
        } catch {
            keep(recordingID)
            throw error
        }
        return save(encoded, duration: buffer.duration, recordingID, details: details)
    }

    /// Makes the recording's pending row. The file goes once the row exists, or when history
    /// keeps nothing; otherwise it stays for the next launch.
    @discardableResult
    public func save(
        _ encoded: EncodedAudio,
        duration: TimeInterval,
        _ recordingID: UUID,
        details: RecordingDetails
    ) -> HistoryEntry? {
        let entry = history.appendPendingRecognition(
            audioData: encoded.data,
            fileExtension: encoded.fileExtension,
            providerID: details.providerID,
            language: details.language,
            audioDurationSeconds: duration,
            model: details.modelID,
            id: recordingID
        )
        if entry != nil || history.maxEntries == 0 {
            discard(recordingID)
        } else {
            keep(recordingID)
        }
        return entry
    }

    /// Nothing of this recording is to be kept: a cancelled start, a press too short.
    public func discard(_ recordingID: UUID) {
        files.removeValue(forKey: recordingID)?.discard()
        keptFiles.removeValue(forKey: recordingID)?.discard()
        settle(recordingID)
    }

    /// The stop did not answer in time. Its audio may still arrive; until then the file
    /// covers it, and an exit has nothing to wait for.
    public func stopTimedOut(_ recordingID: UUID) {
        settle(recordingID)
    }

    /// The transcription was delivered although the recording's row could not be written.
    public func textDelivered(_ recordingID: UUID) {
        discard(recordingID)
    }

    /// History set to 0 during a recording: nothing of it is kept from here on.
    public func historySizeChanged(to size: Int) {
        guard size == 0 else { return }
        files.values.forEach { $0.discard() }
        files = [:]
        keptFiles.values.forEach { $0.discard() }
        keptFiles = [:]
    }

    private func keep(_ recordingID: UUID) {
        if let file = files.removeValue(forKey: recordingID) {
            file.keep()
            keptFiles[recordingID] = file
        }
        settle(recordingID)
    }

    private func settle(_ recordingID: UUID) {
        waitingForRow.remove(recordingID)
        guard waitingForRow.isEmpty else { return }
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }
}
