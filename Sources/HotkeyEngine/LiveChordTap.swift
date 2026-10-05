#if canImport(CoreGraphics) && canImport(ApplicationServices)
import Foundation
import CoreGraphics

/// Every decision the hotkey event tap takes, with the tap taken out: how the tap is
/// created, what each `CGEvent` becomes for the state machine, and which keystrokes it
/// swallows. A `CGEvent` carries exactly the type, key code, raw flags and auto-repeat bit
/// these need, so they can be proved without a tap, a keyboard or a run loop.
///
/// With Live disabled every answer here is what the runner did before Live existed: a
/// listen-only tap for flagsChanged and keyDown on the main run loop that swallows nothing.
extension HotkeyEngineRunner {
    // kVK_Escape.
    static let escapeVirtualKeyCode: Int64 = 53

    /// Where the tap's run-loop source lives.
    enum TapRunLoop: Equatable {
        /// The main run loop, as before Live.
        case main
        /// A thread of its own with its own `CFRunLoop`. An active tap holds every
        /// keystroke in the system until its callback returns, so it must not queue behind
        /// a busy main thread.
        case dedicatedThread
    }

    struct TapSetup: Equatable {
        var options: CGEventTapOptions
        var mask: CGEventMask
        var runLoop: TapRunLoop
    }

    /// How the tap is created for `config`. Only `liveEnabled` matters: an active tap that
    /// sees key-ups exists only while Live is enabled.
    static func tapSetup(for config: HotkeyConfig) -> TapSetup {
        let today: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        guard config.liveEnabled else {
            return TapSetup(options: .listenOnly, mask: today, runLoop: .main)
        }
        return TapSetup(
            options: .defaultTap,
            mask: today | (1 << CGEventType.keyUp.rawValue),
            runLoop: .dedicatedThread
        )
    }

    /// Turns one tapped event into the state machine's input.
    ///
    /// `triggerHeld` comes from `isTriggerHeld` and matters only for the chord key: a chord
    /// key that is not swallowed must not toggle Live either, so both decisions read the
    /// same answer.
    static func translate(
        type: CGEventType,
        keyCode: Int64,
        rawFlags: UInt64,
        isAutorepeat: Bool,
        triggerHeld: Bool,
        config: HotkeyConfig,
        now: TimeInterval
    ) -> HotkeyStateMachine.Event? {
        switch type {
        case .flagsChanged:
            if keyCode == config.trigger.virtualKeyCode {
                return config.trigger.transition(rawFlags: rawFlags) == .pressed
                    ? .triggerDown(at: now)
                    : .triggerUp(at: now)
            }
            return .otherKeyDown(at: now)
        case .keyDown:
            if keyCode == escapeVirtualKeyCode {
                return .escapeDown(at: now)
            }
            if config.liveEnabled, keyCode == config.liveChordKeyCode {
                if isAutorepeat {
                    return .chordKeyRepeat(at: now)
                }
                if triggerHeld {
                    return .chordKeyDown(at: now)
                }
            }
            return .otherKeyDown(at: now)
        default:
            return nil
        }
    }

    /// Whether the trigger is down at the moment of a keystroke.
    ///
    /// Two witnesses, both required. `tracked` is the runner's memory of the trigger's own
    /// flagsChanged events — the same events that give the state machine its trigger-down.
    /// The keystroke's flags are the hardware's word at that instant. Either alone goes
    /// wrong: memory alone stays "held" after a release the tap missed while macOS had it
    /// disabled, and then every `/` would be eaten; flags alone, on a keyboard that reports
    /// no side bits, cannot tell left Option from right.
    static func isTriggerHeld(tracked: Bool, rawFlags: UInt64, trigger: TriggerKey) -> Bool {
        tracked && trigger.transition(rawFlags: rawFlags) == .pressed
    }

    /// Whether the tap must swallow this keystroke.
    ///
    /// Swallowed, tap mode with Live enabled only: the chord key's keyDown while the trigger
    /// is held, the auto-repeats of that keyDown, and its matching keyUp — the keyUp even if
    /// the trigger was let go first, since the application never saw the keyDown. Nothing
    /// else, ever: not the trigger, not Escape, not any other key, and not a chord key that
    /// went down without the trigger (its repeats and keyUp belong to the application).
    ///
    /// The app's own state does not enter: while dictation records, the chord acts as the
    /// plain trigger, and the `/` must still not reach the application.
    ///
    /// `chordKeyOwed` is the one thing carried between keystrokes: a chord keyDown was
    /// swallowed and its keyUp has not arrived yet.
    static func consumes(
        type: CGEventType,
        keyCode: Int64,
        isAutorepeat: Bool,
        triggerHeld: Bool,
        config: HotkeyConfig,
        chordKeyOwed: inout Bool
    ) -> Bool {
        guard config.liveEnabled, config.mode == .tap else {
            chordKeyOwed = false
            return false
        }
        guard keyCode == config.liveChordKeyCode else { return false }

        switch type {
        case .keyDown:
            if isAutorepeat {
                return chordKeyOwed
            }
            chordKeyOwed = triggerHeld
            return triggerHeld
        case .keyUp:
            defer { chordKeyOwed = false }
            return chordKeyOwed
        default:
            return false
        }
    }
}
#endif
