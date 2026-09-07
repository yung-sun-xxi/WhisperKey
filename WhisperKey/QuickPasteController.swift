import AppKit
import Foundation
import HotkeyEngine
import PasteEngine
import os

/// Tracer bullet for the quick-paste popup (#79): hold the trigger, a non-activating
/// panel appears under the cursor showing the current clipboard text, release and that
/// text is pasted where the caret still is.
///
/// Everything here is behind a stored boolean, default off, with no UI. `makeIfEnabled`
/// returns `nil` when the flag is off, so with the feature disabled nothing is
/// constructed, no event tap exists and no key is intercepted for it.
///
/// The hold timer lives here rather than in `HoldToRevealStateMachine`, which stays pure.
@MainActor
final class QuickPasteController {
    /// Hidden flag. Absent reads as `false`, so the feature is off until it is written.
    static let defaultsKey = "WhisperKey.settings.quickPasteEnabled"

    /// Hardcoded for the tracer bullet. Must differ from the recording trigger, which
    /// defaults to right Option.
    static let trigger: TriggerKey = .rightCommand
    static let holdThreshold: TimeInterval = 0.5

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// The only way to build one. Returns `nil` when the stored flag is off.
    static func makeIfEnabled(defaults: UserDefaults = .standard) -> QuickPasteController? {
        guard isEnabled(defaults: defaults) else { return nil }
        return QuickPasteController()
    }

    private let log = Logger(subsystem: "WhisperKey", category: "QuickPaste")
    private let runner: HoldToRevealRunner
    private let outputRouter = TranscriptionOutputRouter()
    private var machine: HoldToRevealStateMachine
    private var panel: QuickPastePanel?
    private var holdTimer: Timer?
    private var pendingText: String?
    private var started = false

    private init() {
        self.runner = HoldToRevealRunner(trigger: Self.trigger)
        self.machine = HoldToRevealStateMachine(holdThreshold: Self.holdThreshold)

        runner.setEventHandler { [weak self] event in
            // The tap source lives on the main run loop, so this is already the main
            // thread; the hop is what makes that a promise rather than an assumption,
            // and `DispatchQueue.main` keeps the events in the order they arrived.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
        }
    }

    /// Starts the event tap. Requires Accessibility permission.
    func start() {
        guard !started else { return }
        started = runner.start()
        if !started {
            log.error("quick-paste CGEventTap could not be created")
        }
    }

    func stop() {
        started = false
        cancelHoldTimer()
        hidePanel()
        runner.stop()
    }

    func setAppState(_ state: HotkeyStateMachine.AppState) {
        apply(machine.setAppState(state))
    }

    // MARK: - Gesture

    private func handle(_ event: HoldToRevealStateMachine.Event) {
        switch event {
        case .triggerDown(let now):
            scheduleHoldTimer(pressedAt: now)
        case .triggerUp, .otherKeyDown:
            cancelHoldTimer()
        case .otherModifierUp, .holdThresholdElapsed:
            break
        }

        apply(machine.process(event))
    }

    private func scheduleHoldTimer(pressedAt: TimeInterval) {
        cancelHoldTimer()
        let timer = Timer(timeInterval: Self.holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                self.apply(
                    self.machine.process(
                        .holdThresholdElapsed(at: pressedAt + Self.holdThreshold)
                    )
                )
            }
        }
        // .common so a menu or a window drag in another application does not stall it.
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func apply(_ output: HoldToRevealOutput?) {
        switch output {
        case nil:
            return
        case .reveal:
            revealPanel()
        case .dismiss:
            pendingText = nil
            hidePanel()
        case .commit:
            let text = pendingText
            pendingText = nil
            hidePanel()
            paste(text)
        }
    }

    private func revealPanel() {
        let text = NSPasteboard.general.string(forType: .string)
        pendingText = text

        hidePanel()
        let panel = QuickPastePanel(content: QuickPasteContent(text: text))
        panel.show(at: NSEvent.mouseLocation)
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func paste(_ text: String?) {
        guard let text, !text.isEmpty else {
            log.info("quick-paste committed with nothing on the clipboard")
            return
        }

        Task { [outputRouter] in
            // The existing clipboard-output path: snapshot, substitute, synthesise ⌘V,
            // restore. Reused unchanged and in the configuration that leaves the
            // clipboard as it was.
            await outputRouter.deliver(
                text: text,
                settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
            )
        }
    }
}
