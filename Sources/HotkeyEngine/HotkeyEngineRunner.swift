#if canImport(CoreGraphics) && canImport(ApplicationServices)
import Foundation
import CoreGraphics
import ApplicationServices
import os

/// Drives a `HotkeyStateMachine` from a `CGEventTap` listening at the session level.
///
/// The tap is listen-only; events are never consumed. The runner re-arms the tap if macOS
/// disables it (e.g. on timeout or after losing accessibility privileges).
public final class HotkeyEngineRunner: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (HotkeyOutput) -> Void

    private let queue = DispatchQueue(label: "WhisperKey.HotkeyEngineRunner")
    private let log = Logger(subsystem: "WhisperKey", category: "HotkeyEngineRunner")
    private var stateMachine: HotkeyStateMachine
    private var handler: OutputHandler?
    private var lastLoggedSuppressionCount: UInt = 0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(config: HotkeyConfig = HotkeyConfig()) {
        self.stateMachine = HotkeyStateMachine(config: config)
    }

    public func setOutputHandler(_ handler: @escaping OutputHandler) {
        queue.sync { self.handler = handler }
    }

    public func setConfig(_ config: HotkeyConfig) {
        queue.sync { self.stateMachine.setConfig(config) }
    }

    public func setAppState(_ state: HotkeyStateMachine.AppState) {
        queue.sync { self.stateMachine.setAppState(state) }
    }

    /// Starts the system-wide event tap. Requires Accessibility permission. Returns
    /// `true` if the tap was created successfully, `false` otherwise.
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

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        let runnerPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyEngineRunner.tapCallback,
            userInfo: runnerPtr
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    private func stopLocked() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handleSystemEvent(_ event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let trigger = stateMachine.config.trigger
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let smEvent: HotkeyStateMachine.Event?
        switch type {
        case .flagsChanged:
            if keyCode == trigger.virtualKeyCode {
                let isPressed = event.flags.containsFlag(for: trigger)
                smEvent = isPressed ? .triggerDown(at: now) : .triggerUp(at: now)
            } else {
                smEvent = .otherKeyDown(at: now)
            }
        case .keyDown:
            smEvent = .otherKeyDown(at: now)
        default:
            smEvent = nil
        }

        guard let inputEvent = smEvent else { return }
        let output = stateMachine.process(inputEvent)

        if stateMachine.transcribingSuppressionCount > lastLoggedSuppressionCount {
            lastLoggedSuppressionCount = stateMachine.transcribingSuppressionCount
            log.info("hotkey suppressed: transcription in flight (count=\(self.lastLoggedSuppressionCount, privacy: .public))")
        }

        if let output {
            handler?(output)
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let runner = Unmanaged<HotkeyEngineRunner>.fromOpaque(refcon).takeUnretainedValue()
        runner.handleSystemEvent(event, type: type)
        return Unmanaged.passUnretained(event)
    }
}

private extension CGEventFlags {
    func containsFlag(for trigger: TriggerKey) -> Bool {
        // CGEventFlags reports the modifier as down across left+right; left/right
        // discrimination comes from the keycode in the caller.
        switch trigger {
        case .rightOption: return contains(.maskAlternate)
        case .rightCommand: return contains(.maskCommand)
        case .rightShift: return contains(.maskShift)
        }
    }
}
#endif
