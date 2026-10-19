import AppKit
import Foundation

/// Apple Music through AppleScript: the one source whose "is playing" is exact (#196, rule 1).
public protocol MusicScripting: Sendable {
    /// Pauses Music if its player state is playing; true when it did.
    func pauseIfPlaying() async -> Bool
    func resume() async
}

/// Moved unchanged from the app target's `AppleMusicRecordingController` (#196).
public final class SystemMusicScripting: MusicScripting {
    private static let bundleIdentifier = "com.apple.Music"

    public init() {}

    public func pauseIfPlaying() async -> Bool {
        guard isMusicRunning else { return false }
        return await run(script: Self.pauseIfPlayingScript) == "paused"
    }

    public func resume() async {
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
