import AppKit
import Foundation

private protocol AppleMusicControlling {
    func pauseIfPlaying() async -> Bool
    func resume() async
}

@MainActor
final class AppleMusicRecordingController {
    private let music: any AppleMusicControlling
    private var activeRecordingID: UUID?
    private var pendingPauseAttempts = Set<UUID>()
    private var pausedByWhisperKey = false

    init() {
        self.music = SystemAppleMusicController()
    }

    func recordingDidStart(enabled: Bool) {
        let recordingID = UUID()
        activeRecordingID = recordingID
        guard enabled else { return }

        pendingPauseAttempts.insert(recordingID)
        Task { [weak self, music] in
            let didPause = await music.pauseIfPlaying()
            self?.pauseAttemptFinished(recordingID: recordingID, didPause: didPause)
        }
    }

    func recordingDidEnd() {
        activeRecordingID = nil
        resumeIfReady()
    }

    private func pauseAttemptFinished(recordingID: UUID, didPause: Bool) {
        pendingPauseAttempts.remove(recordingID)
        if didPause {
            pausedByWhisperKey = true
        }
        resumeIfReady()
    }

    private func resumeIfReady() {
        guard activeRecordingID == nil, pendingPauseAttempts.isEmpty, pausedByWhisperKey else { return }
        pausedByWhisperKey = false

        Task { [music] in
            await music.resume()
        }
    }
}

private final class SystemAppleMusicController: AppleMusicControlling {
    private static let bundleIdentifier = "com.apple.Music"

    func pauseIfPlaying() async -> Bool {
        guard isMusicRunning else { return false }
        return await run(script: Self.pauseIfPlayingScript) == "paused"
    }

    func resume() async {
        guard isMusicRunning else { return }
        _ = await run(script: Self.resumeScript)
    }

    private var isMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleIdentifier
        }
    }

    private func run(script source: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return result?.stringValue
        }.value
    }

    private static let pauseIfPlayingScript = """
    tell application id "com.apple.Music"
        if player state is playing then
            pause
            return "paused"
        end if
    end tell
    return "not-playing"
    """

    private static let resumeScript = """
    tell application id "com.apple.Music" to play
    return "resumed"
    """
}
