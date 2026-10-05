#if canImport(CoreGraphics) && canImport(ApplicationServices)
import Foundation
import CoreGraphics
import ApplicationServices
import os

/// Drives a `HotkeyStateMachine` from a `CGEventTap` listening at the session level.
///
/// With Live disabled the tap is listen-only on the main run loop and events are never
/// consumed. With Live enabled it is an active tap on a thread of its own that swallows the
/// Live chord key and nothing else (see `LiveChordTap.swift` for every decision it takes).
/// Flipping Live rebuilds a running tap. The runner re-arms the tap if macOS disables it
/// (e.g. on timeout or after losing accessibility privileges).
///
/// All state lives behind `queue`: the tap callback may run on the main thread or on the
/// tap's own thread, and the setters are called from the app. The output handler is called
/// on whichever thread the callback ran on, outside the queue.
public final class HotkeyEngineRunner: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (HotkeyOutput) -> Void

    private let queue = DispatchQueue(label: "WhisperKey.HotkeyEngineRunner")
    private let log = Logger(subsystem: "WhisperKey", category: "HotkeyEngineRunner")
    private var stateMachine: HotkeyStateMachine
    private var handler: OutputHandler?
    private var lastLoggedSuppressionCount: UInt = 0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The run loop `runLoopSource` was added to: the main one, or the tap thread's.
    private var tapRunLoop: CFRunLoop?

    /// The trigger's last flagsChanged said "pressed". One of the two witnesses of
    /// `isTriggerHeld`.
    private var triggerTracked = false
    /// A chord keyDown was swallowed and its keyUp is still to come.
    private var chordKeyOwed = false

    public init(config: HotkeyConfig = HotkeyConfig()) {
        self.stateMachine = HotkeyStateMachine(config: config)
    }

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        queue.sync { self.handler = handler }
    }

    /// Applies a new config. A running tap is rebuilt when the config needs a different
    /// kind of tap — that is, when `liveEnabled` flips.
    public func setConfig(_ config: HotkeyConfig) {
        queue.sync {
            let previous = stateMachine.config
            stateMachine.setConfig(config)
            guard eventTap != nil, Self.tapSetup(for: previous) != Self.tapSetup(for: config) else {
                return
            }
            stopLocked()
            if !startLocked() {
                log.error("hotkey tap rebuild failed (liveEnabled=\(config.liveEnabled, privacy: .public))")
            }
        }
    }

    public func setAppState(_ state: HotkeyStateMachine.AppState) {
        queue.sync { self.stateMachine.setAppState(state) }
    }

    /// Tells the engine whether a Live session is open (mutual exclusion with dictation).
    public func setLiveActive(_ active: Bool) {
        queue.sync { self.stateMachine.setLiveActive(active) }
    }

    /// Starts the system-wide event tap. Requires Accessibility permission. Returns
    /// `true` if the tap was created successfully, `false` otherwise. Calling it while the
    /// tap is running does nothing and returns `true`.
    @discardableResult
    public func start() -> Bool {
        var success = false
        queue.sync { success = startLocked() }
        return success
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    private func startLocked() -> Bool {
        guard eventTap == nil else { return true }

        let setup = Self.tapSetup(for: stateMachine.config)
        let runnerPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: setup.options,
            eventsOfInterest: setup.mask,
            callback: HotkeyEngineRunner.tapCallback,
            userInfo: runnerPtr
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        let runLoop: CFRunLoop
        switch setup.runLoop {
        case .main:
            runLoop = CFRunLoopGetMain()
            CFRunLoopAddSource(runLoop, source, .commonModes)
        case .dedicatedThread:
            runLoop = Self.startTapThread(with: source)
        }
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.tapRunLoop = runLoop
        return true
    }

    private func stopLocked() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            if runLoop !== CFRunLoopGetMain() {
                // The tap thread's run loop has nothing left to serve; this ends the thread.
                CFRunLoopStop(runLoop)
            }
        }
        if let tap = eventTap, tapRunLoop !== CFRunLoopGetMain() {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        triggerTracked = false
        chordKeyOwed = false
    }

    /// Starts a thread whose run loop serves `source` and nothing else, and returns that
    /// run loop once the source is on it. The thread ends when the source is removed and
    /// the run loop stopped.
    private static func startTapThread(with source: CFRunLoopSource) -> CFRunLoop {
        final class Handoff: @unchecked Sendable {
            let source: CFRunLoopSource
            var runLoop: CFRunLoop?
            let ready = DispatchSemaphore(value: 0)
            init(source: CFRunLoopSource) { self.source = source }
        }
        let handoff = Handoff(source: source)
        let thread = Thread {
            let runLoop: CFRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, handoff.source, .commonModes)
            handoff.runLoop = runLoop
            handoff.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "WhisperKey.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        handoff.ready.wait()
        return handoff.runLoop!
    }

    /// Returns `true` when the event must not be passed on.
    fileprivate func handleSystemEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            queue.sync {
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let rawFlags = event.flags.rawValue
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        var consume = false
        var output: HotkeyOutput?
        var handler: OutputHandler?
        queue.sync {
            let config = stateMachine.config
            if type == .flagsChanged, keyCode == config.trigger.virtualKeyCode {
                triggerTracked = config.trigger.transition(rawFlags: rawFlags) == .pressed
            }
            let triggerHeld = Self.isTriggerHeld(
                tracked: triggerTracked, rawFlags: rawFlags, trigger: config.trigger
            )

            // Decided here, synchronously: once the callback returns, the event is in the
            // focused application.
            consume = Self.consumes(
                type: type,
                keyCode: keyCode,
                isAutorepeat: isAutorepeat,
                triggerHeld: triggerHeld,
                config: config,
                chordKeyOwed: &chordKeyOwed
            )

            if let inputEvent = Self.translate(
                type: type,
                keyCode: keyCode,
                rawFlags: rawFlags,
                isAutorepeat: isAutorepeat,
                triggerHeld: triggerHeld,
                config: config,
                now: now
            ) {
                output = stateMachine.process(inputEvent)
            }

            if stateMachine.transcribingSuppressionCount > lastLoggedSuppressionCount {
                lastLoggedSuppressionCount = stateMachine.transcribingSuppressionCount
                log.info("hotkey suppressed: transcription in flight (count=\(self.lastLoggedSuppressionCount, privacy: .public))")
            }
            handler = self.handler
        }

        if let output {
            handler?(output)
        }
        return consume
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let runner = Unmanaged<HotkeyEngineRunner>.fromOpaque(refcon).takeUnretainedValue()
        let consume = runner.handleSystemEvent(event, type: type)
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
#endif
