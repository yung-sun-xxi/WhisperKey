import Foundation

/// Which way along the screen an arrow key asks the selection to move. A *screen*
/// direction, not a step through an array: a panel that opened above the cursor draws its
/// rows bottom-up, and "down" is then the other way through the entries. Turning one into
/// the other is the caller's job, not this machine's.
public enum HoldToRevealArrowDirection: Sendable, Equatable {
    case up
    case down
}

public enum HoldToRevealOutput: Sendable, Equatable {
    /// Show the panel.
    case reveal
    /// Take the panel away without choosing anything.
    case dismiss
    /// Take the panel away and act on what it was showing.
    case commit
    /// Move the highlight one row the way the arrow points. The panel stays up.
    case moveSelection(HoldToRevealArrowDirection)
}

/// Pure state machine for the hold-to-reveal gesture. Has no system dependencies and is
/// fully testable, in the same shape as `HotkeyStateMachine`.
///
/// The gesture is symmetric — hold to open, release to choose — and it is deliberately
/// timid: the panel appears only when the trigger is held *alone*, so ordinary chords
/// keep working. A release before the threshold produces no output at all, which is what
/// makes the trigger key behave exactly as it did before the feature existed.
///
/// The machine owns no timer. The threshold is signalled from outside with
/// `.holdThresholdElapsed`, and the machine checks the timestamp it carries — a signal
/// that arrives early, or after the hold was already cancelled, changes nothing.
public struct HoldToRevealStateMachine: Sendable {
    public enum Event: Sendable, Equatable {
        case triggerDown(at: TimeInterval)
        case triggerUp(at: TimeInterval)
        /// Any key other than the trigger going down, including a foreign modifier
        /// being *pressed*. Cancels the gesture.
        case otherKeyDown(at: TimeInterval)
        /// A foreign modifier being *released*. Letting go of Shift must not take the
        /// panel away, so this is explicitly not `otherKeyDown`.
        case otherModifierUp(at: TimeInterval)
        /// An up or down arrow going down. Its own event rather than an `otherKeyDown`,
        /// because while the panel is up it steers the selection instead of abandoning
        /// the gesture. Before the panel is up it is still just another key.
        case arrowKeyDown(direction: HoldToRevealArrowDirection, at: TimeInterval)
        case holdThresholdElapsed(at: TimeInterval)
    }

    private enum Phase: Equatable {
        /// Nothing in flight.
        case idle
        /// Trigger is down, threshold not reached yet.
        case armed(since: TimeInterval)
        /// The panel is up.
        case revealed
        /// The gesture was abandoned; nothing more happens until the trigger is released.
        case cancelled
    }

    public static let defaultHoldThreshold: TimeInterval = 0.5

    public let holdThreshold: TimeInterval
    public private(set) var appState: HotkeyStateMachine.AppState

    private var phase: Phase = .idle

    public var isRevealed: Bool { phase == .revealed }

    public init(
        holdThreshold: TimeInterval = HoldToRevealStateMachine.defaultHoldThreshold,
        appState: HotkeyStateMachine.AppState = .idle
    ) {
        self.holdThreshold = holdThreshold
        self.appState = appState
    }

    /// Tells the machine the application moved to a new state. A recording or a
    /// transcription starting mid-gesture takes the panel away: the two paste paths must
    /// never overlap.
    @discardableResult
    public mutating func setAppState(_ state: HotkeyStateMachine.AppState) -> HoldToRevealOutput? {
        appState = state
        guard state != .idle else { return nil }

        let wasRevealed = phase == .revealed
        phase = .cancelled
        return wasRevealed ? .dismiss : nil
    }

    public mutating func process(_ event: Event) -> HoldToRevealOutput? {
        switch event {
        case .otherModifierUp:
            // Letting go of a modifier that was already held is not a keystroke.
            return nil

        case .triggerDown(let now):
            // Arming is unconditional; whether the panel may actually appear is decided
            // once, on the threshold, so the rule lives in exactly one place.
            phase = .armed(since: now)
            return nil

        case .holdThresholdElapsed(let now):
            guard case .armed(let since) = phase else { return nil }
            guard appState == .idle else {
                phase = .cancelled
                return nil
            }
            guard now - since >= holdThreshold else { return nil }
            phase = .revealed
            return .reveal

        case .triggerUp:
            let wasRevealed = phase == .revealed
            phase = .idle
            return wasRevealed ? .commit : nil

        case .arrowKeyDown(let direction, _):
            switch phase {
            case .revealed:
                // The one key that does not abandon the gesture. The panel stays exactly
                // where it is and the highlight moves.
                return .moveSelection(direction)
            case .armed:
                // No panel yet, so there is nothing to steer and the arrow belongs to
                // whatever the user is typing in. Same answer as any other key.
                phase = .cancelled
                return nil
            case .idle, .cancelled:
                return nil
            }

        case .otherKeyDown:
            switch phase {
            case .armed:
                phase = .cancelled
                return nil
            case .revealed:
                phase = .cancelled
                return .dismiss
            case .idle, .cancelled:
                return nil
            }
        }
    }
}
