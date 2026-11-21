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
/// The tap swallows exactly one thing — an arrow key while the panel is up — and passes
/// everything else through, including the trigger itself. Callbacks arrive on the main run
/// loop, the same as `HotkeyEngineRunner`.
///
/// The swallow decision cannot wait for the state machine. The handler hops to
/// `DispatchQueue.main`, and by the time that hop runs the event has already been
/// delivered to the focused application — an Option-Down in the user's document. So the
/// tap answers from `setRevealed`, a flag the panel's owner sets when it puts the panel on
/// screen and clears when it takes it away, read synchronously inside the callback.
public final class HoldToRevealRunner: @unchecked Sendable {
    public typealias EventHandler = @Sendable (HoldToRevealStateMachine.Event) -> Void

    private let queue = DispatchQueue(label: "WhisperKey.HoldToRevealRunner")
    private var trigger: TriggerKey
    private var handler: EventHandler?
    /// Whether the panel is on screen right now. Written from the main thread by whoever
    /// owns the panel, and read on the main run loop where the tap delivers — the same
    /// thread the tap callback runs on, which is why the read needs no hop of its own.
    private var revealed = false

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

    /// Tells the tap whether the panel is currently on screen, and therefore whether an
    /// arrow key belongs to the popup or to the application underneath.
    ///
    /// Must be called on the main thread, from the same place that shows and hides the
    /// panel, so that the flag can never say "up" while nothing is drawn.
    public func setRevealed(_ revealed: Bool) {
        self.revealed = revealed
    }

    /// Starts the tap. Requires Accessibility permission. Returns `true` on success.
    @discardableResult
    public func start() -> Bool {
        var success = false
        queue.sync { success = startLocked() }
        return success
    }

    public func stop() {
        // A tap that is gone swallows nothing; leaving the flag set would make a restart
        // begin by eating arrows with no panel on screen.
        revealed = false
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

        // Not `.listenOnly`: an arrow pressed while the panel is up has to be swallowed,
        // or it reaches the focused text field as Option-Down or Shift-Down — the trigger
        // is a modifier, so the arrow never arrives bare. Everything else the callback
        // sees is passed straight back out.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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

    /// Returns `true` when the event must not be passed on.
    fileprivate func handleSystemEvent(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        let translated = Self.translate(
            type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            rawFlags: event.flags.rawValue,
            trigger: self.trigger,
            now: CFAbsoluteTimeGetCurrent()
        )

        // Decided here, before the handler's hop to the main queue: by the time that hop
        // runs the event would already be in the user's document.
        let consume = Self.consumes(translated, isRevealed: revealed)

        if let translated {
            handler?(translated)
        }
        return consume
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
            if let direction = ArrowKey.direction(keyCode: keyCode) {
                return .arrowKeyDown(direction: direction, at: now)
            }
            return .otherKeyDown(at: now)
        default:
            return nil
        }
    }

    /// Whether the tap must swallow the event it has just translated.
    ///
    /// Exactly one thing is swallowed, and only while the panel is up: an arrow the popup
    /// is about to act on. Everything else — every other key, the trigger, and every arrow
    /// pressed with no panel on screen — is passed through untouched, which is what keeps
    /// the arrow keys ordinary the rest of the time.
    static func consumes(_ event: HoldToRevealStateMachine.Event?, isRevealed: Bool) -> Bool {
        guard isRevealed else { return false }
        if case .arrowKeyDown = event { return true }
        return false
    }

    /// The two arrows the popup understands, by virtual key code.
    ///
    /// Left and right are deliberately absent: there is nothing sideways to move to, so
    /// they stay ordinary keys that cancel the gesture and reach the application.
    enum ArrowKey {
        static let up: Int64 = 126     // kVK_UpArrow
        static let down: Int64 = 125   // kVK_DownArrow

        static func direction(keyCode: Int64) -> HoldToRevealArrowDirection? {
            switch keyCode {
            case up: return .up
            case down: return .down
            default: return nil
            }
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let runner = Unmanaged<HoldToRevealRunner>.fromOpaque(refcon).takeUnretainedValue()
        let consume = runner.handleSystemEvent(event, type: type)
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
#endif
