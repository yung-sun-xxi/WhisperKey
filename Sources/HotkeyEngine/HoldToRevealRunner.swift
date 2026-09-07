#if canImport(CoreGraphics) && canImport(ApplicationServices)
import Foundation
import CoreGraphics
import ApplicationServices

/// Turns a session-level `CGEventTap` into `HoldToRevealStateMachine.Event` values.
///
/// Deliberately thin: it owns no state machine, no timer and no panel. The hold timer
/// belongs with whoever owns the panel, and the state machine is pure so it can be proved
/// in tests — neither of which is true of anything in this file, which is why nothing but
/// event translation lives here.
///
/// The tap is listen-only; events are never consumed. Callbacks arrive on the main run
/// loop, the same as `HotkeyEngineRunner`.
public final class HoldToRevealRunner: @unchecked Sendable {
    public typealias EventHandler = @Sendable (HoldToRevealStateMachine.Event) -> Void

    private let queue = DispatchQueue(label: "WhisperKey.HoldToRevealRunner")
    private var trigger: TriggerKey
    private var handler: EventHandler?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(trigger: TriggerKey) {
        self.trigger = trigger
    }

    public func setEventHandler(_ handler: @escaping EventHandler) {
        queue.sync { self.handler = handler }
    }

    public func setTrigger(_ trigger: TriggerKey) {
        queue.sync { self.trigger = trigger }
    }

    /// Starts the tap. Requires Accessibility permission. Returns `true` on success.
    @discardableResult
    public func start() -> Bool {
        var success = false
        queue.sync { success = startLocked() }
        return success
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    public var isRunning: Bool {
        queue.sync { eventTap != nil }
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
            callback: HoldToRevealRunner.tapCallback,
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

        let translated = Self.translate(
            type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            rawFlags: event.flags.rawValue,
            trigger: self.trigger,
            now: CFAbsoluteTimeGetCurrent()
        )

        guard let translated else { return }
        handler?(translated)
    }

    /// The whole of the tap's decision-making, with the tap taken out of it.
    ///
    /// A `CGEvent` carries exactly three things this runner cares about — its type, its
    /// key code and its raw flags — so lifting them out leaves a pure function that can be
    /// proved without an event tap, a keyboard or a run loop.
    static func translate(
        type: CGEventType,
        keyCode: Int64,
        rawFlags: UInt64,
        trigger: TriggerKey,
        now: TimeInterval
    ) -> HoldToRevealStateMachine.Event? {
        switch type {
        case .flagsChanged:
            if keyCode == trigger.virtualKeyCode {
                return trigger.transition(rawFlags: rawFlags) == .pressed
                    ? .triggerDown(at: now)
                    : .triggerUp(at: now)
            }
            // A foreign modifier coming *up* is not a keystroke and must not cancel:
            // letting go of a Shift that was already held has to leave the panel alone.
            // Only `ModifierKey.transition` can tell the two directions apart, because
            // the shared flag bit reads the same either way while the other side is held.
            return ModifierKey.transition(keyCode: keyCode, rawFlags: rawFlags) == .pressed
                ? .otherKeyDown(at: now)
                : .otherModifierUp(at: now)
        case .keyDown:
            return .otherKeyDown(at: now)
        default:
            return nil
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let runner = Unmanaged<HoldToRevealRunner>.fromOpaque(refcon).takeUnretainedValue()
        runner.handleSystemEvent(event, type: type)
        return Unmanaged.passUnretained(event)
    }
}
#endif
