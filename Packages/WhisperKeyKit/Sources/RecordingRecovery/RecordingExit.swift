import Foundation

/// Quitting the app without losing the recording (#233).
///
/// Asked when the app is about to terminate. It answers at once: exit now, or save first.
/// In the second case it stops the recorder, waits until every recording has its row,
/// resumes the music, and calls `reply` exactly once, within `bound` whatever hangs. The
/// recovery file covers audio that did not make it.
///
/// Nothing is transcribed on the way out.
@MainActor
public final class RecordingExit {
    public enum Answer: Equatable {
        case exitNow
        case saveFirst
    }

    /// What the microphone is doing, as far as nobody has asked it to stop yet.
    public enum Microphone: Equatable {
        case idle
        case starting
        case recording
    }

    public struct Actions {
        public var microphone: () -> Microphone
        public var cancelStart: () -> Void
        /// Stops the recorder and hands its audio to the keeper.
        public var stopAndSave: () async -> Void
        public var musicNeedsResuming: () -> Bool
        public var resumeMusic: () async -> Void
        public var reply: () -> Void

        public init(
            microphone: @escaping () -> Microphone,
            cancelStart: @escaping () -> Void,
            stopAndSave: @escaping () async -> Void,
            musicNeedsResuming: @escaping () -> Bool,
            resumeMusic: @escaping () async -> Void,
            reply: @escaping () -> Void
        ) {
            self.microphone = microphone
            self.cancelStart = cancelStart
            self.stopAndSave = stopAndSave
            self.musicNeedsResuming = musicNeedsResuming
            self.resumeMusic = resumeMusic
            self.reply = reply
        }
    }

    /// The whole exit, music included. `scripts/install-app.sh` sends SIGKILL 3 s after
    /// SIGTERM.
    public nonisolated static let defaultBound: TimeInterval = 2
    /// The part of the bound the save may use up, so the music still gets its turn when the
    /// recorder hangs.
    private static let saveShare = 0.75

    private enum Phase {
        case notAsked
        case saving
        case replied
    }

    private let keeper: RecordingKeeper
    private let actions: Actions
    private let bound: TimeInterval
    private var phase = Phase.notAsked

    public init(keeper: RecordingKeeper, actions: Actions, bound: TimeInterval = RecordingExit.defaultBound) {
        self.keeper = keeper
        self.actions = actions
        self.bound = bound
    }

    /// An exit was asked for and has not been answered yet.
    public var isPending: Bool { phase == .saving }

    public func request() -> Answer {
        switch phase {
        case .saving: return .saveFirst
        case .replied: return .exitNow
        case .notAsked: break
        }

        let microphone = actions.microphone()
        if microphone == .starting { actions.cancelStart() }
        guard microphone == .recording || keeper.isWaitingForRow || actions.musicNeedsResuming() else {
            return .exitNow
        }

        phase = .saving
        let deadline = DispatchTime.now() + bound
        Task {
            await Self.run(before: DispatchTime.now() + bound * Self.saveShare) { [self] in
                if microphone == .recording { await actions.stopAndSave() }
                await keeper.waitForRows()
            }
            if actions.musicNeedsResuming() {
                await Self.run(before: deadline) { [self] in await actions.resumeMusic() }
            }
            // The only reply: `notAsked` is left once, so this task runs once.
            phase = .replied
            actions.reply()
        }
        return .saveFirst
    }

    /// Runs `work` and returns when it finishes or the deadline passes, whichever is first.
    /// Work that is late goes on; nobody waits for it.
    private static func run(before deadline: DispatchTime, _ work: @escaping @MainActor () async -> Void) async {
        let now = DispatchTime.now()
        guard deadline > now else { return }
        let nanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var waiting: CheckedContinuation<Void, Never>? = continuation
            func resume() {
                waiting?.resume()
                waiting = nil
            }
            Task { @MainActor in
                await work()
                resume()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: nanoseconds)
                resume()
            }
        }
    }
}

/// Ends the process by force when the exit did not: the main thread is stuck, a modal panel
/// blocks it, or the reply got lost. Runs on its own queue and needs nothing of the app.
public final class ExitBackstop: @unchecked Sendable {
    /// After `RecordingExit.defaultBound`, before the 3 s of `scripts/install-app.sh`.
    public static let defaultDelay: TimeInterval = 2.6

    private let delay: TimeInterval
    private let exit: @Sendable () -> Void
    private let queue = DispatchQueue(label: "WhisperKey.ExitBackstop", qos: .userInteractive)
    private let lock = NSLock()
    private var isArmed = false

    public init(delay: TimeInterval = ExitBackstop.defaultDelay, exit: @escaping @Sendable () -> Void = { _exit(0) }) {
        self.delay = delay
        self.exit = exit
    }

    /// Only the first call counts: the time runs from the first reason to exit.
    public func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard !isArmed else { return }
        isArmed = true
        queue.asyncAfter(deadline: .now() + delay) { [exit] in exit() }
    }
}
