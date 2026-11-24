import AppKit
import os
import RecordingRecovery

/// How the app asks itself to quit, and what ends it when that does not work (#233).
///
/// After `.terminateLater` AppKit runs a nested run loop in the modal-panel mode until the
/// reply. The main queue cannot drain inside that loop when `NSApp.terminate` was called from
/// a main-queue block or a MainActor task, and then the saving task never starts (proved on
/// macOS 27). So every terminate of the app's own is issued from the run loop.
@MainActor
final class AppTermination {
    private nonisolated static let log = Logger(subsystem: "WhisperKey", category: "Termination")
    private static var wasAsked = false

    nonisolated let backstop = ExitBackstop()
    private var sigtermSource: DispatchSourceSignal?

    /// Quits the app. Callable from anywhere. Does nothing once the delegate was asked: AppKit
    /// answers a second `terminate` by quitting at once, without asking again, which would cut
    /// off the save the first one is waiting for (proved on macOS 27).
    nonisolated static func request() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                guard !wasAsked else { return }
                NSApp.terminate(nil)
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// AppKit is asking the delegate whether to quit, whoever asked AppKit.
    static func noteAsked() {
        wasAsked = true
    }

    /// SIGTERM becomes an ordinary quit. The signal is watched on a background queue, so the
    /// backstop is armed even when the main thread is stuck. An empty handler rather than
    /// SIG_IGN: an ignored signal stays ignored in the child processes the app starts.
    func listenForSIGTERM() {
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: DispatchQueue(label: "WhisperKey.SIGTERM", qos: .userInteractive)
        )
        source.setEventHandler { @Sendable [backstop] in
            Self.log.notice("SIGTERM: quitting")
            backstop.arm()
            Self.request()
        }
        source.resume()
        sigtermSource = source
    }

    /// The defence against a second `terminate` that did not come through `request()`, such
    /// as a logout during a Quit: AppKit is about to end the process while the save is still
    /// running. Runs the loop until it is done; the backstop bounds it.
    func finishPendingExit(while isSaving: () -> Bool) {
        while isSaving() {
            RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.05))
        }
    }
}
