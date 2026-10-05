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
    public var escapeToCancelRecording: Bool
    /// Whether the trigger plus `liveChordKeyCode` opens Live. Off, the chord key is an
    /// ordinary key and every output is what it was before Live existed.
    public var liveEnabled: Bool
    /// Virtual key code of the second key of the Live chord. 44 is `kVK_ANSI_Slash`.
    public var liveChordKeyCode: Int64

    public init(
        trigger: TriggerKey = .rightOption,
        mode: TriggerMode = .tap,
        escapeToCancelRecording: Bool = true,
        liveEnabled: Bool = false,
        liveChordKeyCode: Int64 = 44
    ) {
        self.trigger = trigger
        self.mode = mode
        self.escapeToCancelRecording = escapeToCancelRecording
        self.liveEnabled = liveEnabled
        self.liveChordKeyCode = liveChordKeyCode
    }
}

public enum HotkeyOutput: Sendable, Equatable {
    case recordingShouldStart
    case recordingShouldStop
    case recordingShouldCancel
    /// The Live chord was pressed: open Live if it is closed, close it if it is open.
    case liveShouldToggle
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
        case escapeDown(at: TimeInterval)
        /// The Live chord key went down while the trigger was held. Only produced while
        /// Live is enabled; otherwise the same keystroke is `otherKeyDown`.
        case chordKeyDown(at: TimeInterval)
        /// An auto-repeat of the chord key (`keyboardEventAutorepeat`). Never toggles Live.
        case chordKeyRepeat(at: TimeInterval)
    }

    public static let tapMaxDuration: TimeInterval = 0.4
    public static let holdAbortWindow: TimeInterval = 0.08

    public private(set) var config: HotkeyConfig
    public private(set) var appState: AppState
    public private(set) var transcribingSuppressionCount: UInt = 0
    /// Whether a Live session is open, as told by the app. Live and dictation never share
    /// the microphone, so while this is set the trigger alone starts nothing.
    public private(set) var isLiveActive: Bool = false

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

    /// Tells the state machine whether a Live session is open. Kept apart from `AppState`
    /// because Live is not a dictation state, and only consulted while Live is enabled.
    public mutating func setLiveActive(_ active: Bool) {
        isLiveActive = active
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
        if case .escapeDown(let t) = event, !config.escapeToCancelRecording {
            return processTapMode(.otherKeyDown(at: t))
        }
        if !config.liveEnabled {
            switch event {
            case .chordKeyDown(let t), .chordKeyRepeat(let t):
                return processTapMode(.otherKeyDown(at: t))
            default:
                break
            }
        }

        switch (appState, event) {
        case (.transcribing, .triggerDown), (.transcribing, .triggerUp):
            transcribingSuppressionCount &+= 1
            return nil
        case (.transcribing, .otherKeyDown):
            return nil
        case (.transcribing, .escapeDown):
            return nil

        case (.idle, .triggerDown(let t)):
            pressedAt = t
            otherKeySeen = false
            return nil

        case (.idle, .triggerUp(let t)):
            if config.liveEnabled && isLiveActive {
                // Live has the microphone; only the chord does anything now.
                resetHoldState()
                return nil
            }
            return finishHoldFromIdle(now: t)

        case (.idle, .chordKeyDown):
            // `pressedAt` is set only by a trigger-down seen in idle and cleared by any
            // app-state change, so this is "the press began in idle and is still held".
            guard pressedAt != nil else { return nil }
            // The press belongs to Live now: its trigger-up must not start dictation.
            otherKeySeen = true
            return .liveShouldToggle

        case (.idle, .chordKeyRepeat):
            // Never a toggle, but still a key held during the press: not a clean tap.
            if pressedAt != nil {
                otherKeySeen = true
            }
            return nil

        case (.recording, .chordKeyDown), (.recording, .chordKeyRepeat):
            // While dictating, the chord is the plain trigger: the trigger-down already
            // stopped the recording, and the chord key adds nothing.
            return nil

        case (.transcribing, .chordKeyDown), (.transcribing, .chordKeyRepeat):
            return nil

        case (.idle, .otherKeyDown):
            if pressedAt != nil {
                otherKeySeen = true
            }
            return nil
        case (.idle, .escapeDown):
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

        case (.recording, .escapeDown):
            resetHoldState()
            return .recordingShouldCancel
        }
    }

    private mutating func processHoldMode(_ event: Event) -> HotkeyOutput? {
        if case .escapeDown(let t) = event, !config.escapeToCancelRecording {
            return processHoldMode(.otherKeyDown(at: t))
        }
        // Hold-mode Live is not built yet: the chord key is an ordinary key, as today.
        switch event {
        case .chordKeyDown(let t), .chordKeyRepeat(let t):
            return processHoldMode(.otherKeyDown(at: t))
        default:
            break
        }

        switch (appState, event) {
        case (.transcribing, .triggerDown), (.transcribing, .triggerUp):
            transcribingSuppressionCount &+= 1
            return nil
        case (.transcribing, .otherKeyDown):
            return nil
        case (.transcribing, .escapeDown):
            return nil

        case (.idle, .triggerDown(let t)):
            activeHoldStartedAt = t
            return .recordingShouldStart

        case (.idle, .triggerUp):
            return stopActiveHoldIfNeeded()

        case (.idle, .otherKeyDown(let t)):
            return abortActiveHoldIfNeeded(now: t)

        case (.idle, .escapeDown):
            return cancelActiveHoldIfNeeded()

        case (.recording, .triggerDown):
            return nil

        case (.recording, .triggerUp):
            return stopActiveHoldIfNeeded()

        case (.recording, .otherKeyDown(let t)):
            return abortActiveHoldIfNeeded(now: t)

        case (.recording, .escapeDown):
            resetHoldState()
            return .recordingShouldCancel

        case (_, .chordKeyDown), (_, .chordKeyRepeat):
            return nil   // Unreachable: remapped above.
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

    private mutating func cancelActiveHoldIfNeeded() -> HotkeyOutput? {
        guard activeHoldStartedAt != nil else { return nil }
        resetHoldState()
        return .recordingShouldCancel
    }
}
