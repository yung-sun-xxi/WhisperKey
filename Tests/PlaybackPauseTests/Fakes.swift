import Foundation
@testable import PlaybackPause

/// Apple Music as AppleScript sees it: playing or not, and how often it was told to pause or play.
final class FakeMusic: MusicScripting, @unchecked Sendable {
    private let lock = NSLock()
    private var _playing: Bool
    private var _pauseCalls = 0
    private var _resumeCalls = 0

    init(playing: Bool = false) {
        _playing = playing
    }

    var playing: Bool { lock.withLock { _playing } }
    var pauseCalls: Int { lock.withLock { _pauseCalls } }
    var resumeCalls: Int { lock.withLock { _resumeCalls } }

    func pauseIfPlaying() async -> Bool {
        lock.withLock {
            _pauseCalls += 1
            guard _playing else { return false }
            _playing = false
            return true
        }
    }

    func resume() async {
        lock.withLock {
            _resumeCalls += 1
            _playing = true
        }
    }
}

/// Core Audio's process list, set by the test between steps.
final class FakeProbe: AudioOutputProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AudioProcess]
    private var _calls = 0

    init(_ processes: [AudioProcess] = []) {
        _processes = processes
    }

    var processes: [AudioProcess] {
        get { lock.withLock { _processes } }
        set { lock.withLock { _processes = newValue } }
    }

    var calls: Int { lock.withLock { _calls } }

    func audioProcesses() async -> [AudioProcess] {
        lock.withLock {
            _calls += 1
            return _processes
        }
    }
}

/// Counts Play/Pause key presses.
final class FakeKeyPoster: MediaKeyPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts = 0

    var posts: Int { lock.withLock { _posts } }

    func postPlayPause() {
        lock.withLock { _posts += 1 }
    }
}

extension AudioProcess {
    static func chrome(running: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: "com.google.Chrome.helper", pid: 500, isRunningOutput: running)
    }

    static func vlc(running: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: "org.videolan.vlc", pid: 600, isRunningOutput: running)
    }

    static func appleMusic(running: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: "com.apple.Music", pid: 700, isRunningOutput: running)
    }

    static func systemSounds(running: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: "com.apple.systemsoundserverd", pid: 800, isRunningOutput: running)
    }
}
