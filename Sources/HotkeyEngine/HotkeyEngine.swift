import Foundation

public enum TriggerKey: String, CaseIterable, Codable, Sendable, Equatable {
    case rightOption
    case rightCommand
    case rightShift

    public var displayName: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightShift: return "Right Shift"
        }
    }

    public var virtualKeyCode: Int64 {
        switch self {
        case .rightOption: return 61   // kVK_RightOption
        case .rightCommand: return 54  // kVK_RightCommand
        case .rightShift: return 60    // kVK_RightShift
        }
    }
}

public enum TriggerMode: String, CaseIterable, Codable, Sendable, Equatable {
    case tap
    case hold

    public var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .hold: return "Hold"
        }
    }
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
    public static let holdAbortWindow: TimeInterval = 0.08

    public private(set) var config: HotkeyConfig
    public private(set) var appState: AppState
    public private(set) var transcribingSuppressionCount: UInt = 0

    private var pressedAt: TimeInterval?
    private var otherKeySeen: Bool
    private var activeHoldStartedAt: TimeInterval?

    public init(config: HotkeyConfig = HotkeyConfig(), appState: AppState = .idle) {
        self.config = config
        self.appState = appState
        self.pressedAt = nil
        self.otherKeySeen = false
        self.activeHoldStartedAt = nil
    }

    public mutating func setConfig(_ config: HotkeyConfig) {
        self.config = config
        resetHoldState()
    }

    /// Tells the state machine that the application transitioned to a new state.
    /// Drives ignoring of trigger events while transcribing, etc.
    public mutating func setAppState(_ state: AppState) {
        appState = state
        switch (config.mode, state) {
        case (.hold, .recording):
            break
        default:
            resetHoldState()
        }
    }

    public mutating func process(_ event: Event) -> HotkeyOutput? {
        switch config.mode {
        case .tap:
            return processTapMode(event)
        case .hold:
            return processHoldMode(event)
        }
    }

    private mutating func processTapMode(_ event: Event) -> HotkeyOutput? {
        switch (appState, event) {
        case (.transcribing, .triggerDown), (.transcribing, .triggerUp):
            transcribingSuppressionCount &+= 1
            return nil
        case (.transcribing, .otherKeyDown):
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

    private mutating func processHoldMode(_ event: Event) -> HotkeyOutput? {
        switch (appState, event) {
        case (.transcribing, .triggerDown), (.transcribing, .triggerUp):
            transcribingSuppressionCount &+= 1
            return nil
        case (.transcribing, .otherKeyDown):
            return nil

        case (.idle, .triggerDown(let t)):
            activeHoldStartedAt = t
            return .recordingShouldStart

        case (.idle, .triggerUp):
            return stopActiveHoldIfNeeded()

        case (.idle, .otherKeyDown(let t)):
            return abortActiveHoldIfNeeded(now: t)

        case (.recording, .triggerDown):
            return nil

        case (.recording, .triggerUp):
            return stopActiveHoldIfNeeded()

        case (.recording, .otherKeyDown(let t)):
            return abortActiveHoldIfNeeded(now: t)
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
        activeHoldStartedAt = nil
    }

    private mutating func stopActiveHoldIfNeeded() -> HotkeyOutput? {
        guard activeHoldStartedAt != nil else { return nil }
        resetHoldState()
        return .recordingShouldStop
    }

    private mutating func abortActiveHoldIfNeeded(now: TimeInterval) -> HotkeyOutput? {
        guard let started = activeHoldStartedAt else { return nil }
        let elapsed = now - started
        guard elapsed >= 0, elapsed <= Self.holdAbortWindow else {
            return nil
        }
        resetHoldState()
        return .recordingShouldStop
    }
}
