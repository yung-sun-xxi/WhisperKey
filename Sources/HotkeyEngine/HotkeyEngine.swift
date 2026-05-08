import Foundation

public enum TriggerKey: Sendable, Equatable {
    case rightOption
    case rightCommand
    case rightShift

    public var virtualKeyCode: Int64 {
        switch self {
        case .rightOption: return 61   // kVK_RightOption
        case .rightCommand: return 54  // kVK_RightCommand
        case .rightShift: return 60    // kVK_RightShift
        }
    }
}

public enum TriggerMode: Sendable, Equatable {
    case tap
    case hold
}

public struct HotkeyConfig: Sendable, Equatable {
    public var trigger: TriggerKey
    public var mode: TriggerMode

    public init(trigger: TriggerKey = .rightOption, mode: TriggerMode = .tap) {
        self.trigger = trigger
        self.mode = mode
    }
}

public enum HotkeyOutput: Sendable, Equatable {
    case recordingShouldStart
    case recordingShouldStop
}

/// Pure state machine for hotkey detection. Has no system dependencies and is fully testable.
///
/// Implements the asymmetric filter from the PRD: starting a recording requires a clean tap
/// (no other keys pressed during the hold AND duration ≤ 400 ms). Stopping in tap mode
/// fires on any trigger keyDown without further checks.
public struct HotkeyStateMachine: Sendable {
    public enum AppState: Sendable, Equatable {
        case idle
        case recording
        case transcribing
    }

    public enum Event: Sendable, Equatable {
        case triggerDown(at: TimeInterval)
        case triggerUp(at: TimeInterval)
        case otherKeyDown(at: TimeInterval)
    }

    public static let tapMaxDuration: TimeInterval = 0.4

    public private(set) var config: HotkeyConfig
    public private(set) var appState: AppState

    private var pressedAt: TimeInterval?
    private var otherKeySeen: Bool

    public init(config: HotkeyConfig = HotkeyConfig(), appState: AppState = .idle) {
        self.config = config
        self.appState = appState
        self.pressedAt = nil
        self.otherKeySeen = false
    }

    public mutating func setConfig(_ config: HotkeyConfig) {
        self.config = config
        resetHoldState()
    }

    /// Tells the state machine that the application transitioned to a new state.
    /// Drives ignoring of trigger events while transcribing, etc.
    public mutating func setAppState(_ state: AppState) {
        appState = state
        resetHoldState()
    }

    public mutating func process(_ event: Event) -> HotkeyOutput? {
        switch (appState, event) {
        case (.transcribing, _):
            return nil

        case (.idle, .triggerDown(let t)):
            pressedAt = t
            otherKeySeen = false
            return nil

        case (.idle, .triggerUp(let t)):
            return finishHoldFromIdle(now: t)

        case (.idle, .otherKeyDown):
            if pressedAt != nil {
                otherKeySeen = true
            }
            return nil

        case (.recording, .triggerDown):
            resetHoldState()
            return .recordingShouldStop

        case (.recording, .triggerUp):
            return nil

        case (.recording, .otherKeyDown):
            return nil
        }
    }

    private mutating func finishHoldFromIdle(now: TimeInterval) -> HotkeyOutput? {
        guard let started = pressedAt else { return nil }
        defer { resetHoldState() }
        let duration = now - started
        guard !otherKeySeen, duration <= Self.tapMaxDuration, duration >= 0 else {
            return nil
        }
        return .recordingShouldStart
    }

    private mutating func resetHoldState() {
        pressedAt = nil
        otherKeySeen = false
    }
}
