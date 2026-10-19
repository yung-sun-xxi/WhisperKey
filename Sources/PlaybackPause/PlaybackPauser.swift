import Foundation

/// Pauses whatever is playing when a recording starts and resumes it when the microphone
/// stops (#196), the way an incoming call pauses media on the iPhone.
///
/// - Apple Music goes through AppleScript only: `player state is playing` is exact, and what
///   AppleScript paused AppleScript resumes (rule 1).
/// - Anything else goes through the Play/Pause media key, posted only when an eligible
///   process runs output (rule 2). The end posts it again only when the paused process is
///   still there and no other eligible process runs output (rule 3).
/// - A recording uses one method: when Music was playing, no key is posted (rule 4).
///
/// Overlapping recordings share one pause and resume once; a recording that paused
/// nothing resumes nothing.
@MainActor
public final class PlaybackPauser {
    private let music: any MusicScripting
    private let probe: any AudioOutputProbing
    private let keyPoster: any MediaKeyPosting
    private let ownPID: pid_t

    private var activeRecordingID: UUID?
    private var pendingPauseAttempts = Set<UUID>()
    /// Music was paused through AppleScript and waits to be resumed the same way.
    private var musicPaused = false
    /// The process the media key was posted for, waiting for the key at the end.
    private var keyPausedPID: pid_t?
    /// The end probe for `keyPausedPID` has not answered yet.
    private var keyResumeInFlight = false
    /// Work started by the two entry points, removed as each piece finishes.
    private var pendingWork: [UUID: Task<Void, Never>] = [:]

    public init(
        music: any MusicScripting,
        probe: any AudioOutputProbing,
        keyPoster: any MediaKeyPosting,
        ownPID: pid_t
    ) {
        self.music = music
        self.probe = probe
        self.keyPoster = keyPoster
        self.ownPID = ownPID
    }

    /// AppleScript, Core Audio and the HID event tap, with this process's PID ignored.
    public convenience init() {
        self.init(
            music: SystemMusicScripting(),
            probe: SystemAudioOutputProbe(),
            keyPoster: SystemMediaKeyPoster(),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    public func recordingDidStart(enabled: Bool) {
        let recordingID = UUID()
        activeRecordingID = recordingID
        // An earlier recording's pause is still held: this recording inherits it.
        guard enabled, !holdsPause else { return }

        pendingPauseAttempts.insert(recordingID)
        track { [music, probe] in
            if await music.pauseIfPlaying() {
                self.pauseAttemptFinished(recordingID: recordingID, pausedMusic: true)
                return
            }
            let processes = await probe.audioProcesses()
            // Back on the main actor: decide and post in one step, so two attempts in
            // flight at once cannot both post.
            if !self.holdsPause,
               let target = processes.first(where: { $0.isRunningOutput && self.isEligible($0) }) {
                self.keyPoster.postPlayPause()
                self.keyPausedPID = target.pid
            }
            self.pauseAttemptFinished(recordingID: recordingID, pausedMusic: false)
        }
    }

    public func recordingDidEnd() {
        activeRecordingID = nil
        resumeIfReady()
    }

    /// Waits until every pause and resume started so far has finished. For tests.
    func waitForPendingWork() async {
        while let task = pendingWork.values.first {
            await task.value
        }
    }

    private var holdsPause: Bool {
        musicPaused || keyPausedPID != nil
    }

    private func isEligible(_ process: AudioProcess) -> Bool {
        PlaybackEligibility.isEligible(process, ownPID: ownPID)
    }

    private func pauseAttemptFinished(recordingID: UUID, pausedMusic: Bool) {
        pendingPauseAttempts.remove(recordingID)
        if pausedMusic {
            musicPaused = true
        }
        resumeIfReady()
    }

    private func resumeIfReady() {
        guard activeRecordingID == nil, pendingPauseAttempts.isEmpty else { return }

        if musicPaused {
            musicPaused = false
            track { [music] in
                await music.resume()
            }
        }

        if let pausedPID = keyPausedPID, !keyResumeInFlight {
            keyResumeInFlight = true
            track { [probe] in
                let processes = await probe.audioProcesses()
                self.keyResumeInFlight = false
                // A new recording started while the probe ran: it inherits the pause and
                // resumes it when it ends.
                guard self.activeRecordingID == nil else { return }
                self.keyPausedPID = nil

                let pausedProcessIsThere = processes.contains { $0.pid == pausedPID }
                let otherPlayerIsOutputting = processes.contains {
                    $0.pid != pausedPID && $0.isRunningOutput && self.isEligible($0)
                }
                guard pausedProcessIsThere, !otherPlayerIsOutputting else { return }
                self.keyPoster.postPlayPause()
            }
        }
    }

    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingWork[id] = Task { @MainActor in
            await operation()
            self.pendingWork[id] = nil
        }
    }
}
