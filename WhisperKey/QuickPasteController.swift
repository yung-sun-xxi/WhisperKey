import AppKit
import ClipboardHistoryStore
import Foundation
import HotkeyEngine
import PasteEngine
import os

/// The quick-paste popup: hold the trigger, a non-activating panel appears under the
/// cursor listing the most recent clipboard entries, release and the newest is pasted
/// where the caret still is.
///
/// Everything here is behind a stored boolean, default off, with no UI. `AppCoordinator`
/// consults `isEnabled` before it builds the store, the monitor or this controller, so
/// with the feature disabled nothing is constructed, no watcher polls the pasteboard, no
/// event tap exists and no key is intercepted for it.
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

    /// How many entries the panel lists. Hardcoded until the settings UI exists.
    static let visibleEntryCount = 5

    private let log = Logger(subsystem: "WhisperKey", category: "QuickPaste")
    private let runner: HoldToRevealRunner
    private let outputRouter = TranscriptionOutputRouter()
    private var machine: HoldToRevealStateMachine
    private var panel: QuickPastePanel?
    private var holdTimer: Timer?
    private var pendingText: String?
    private var started = false

    /// The history the panel renders. Filled by `ClipboardMonitor`, not read live off the
    /// pasteboard.
    private let store: ClipboardHistoryStore
    /// Silenced around this controller's own clipboard swap, so the popup's temporary use
    /// of the clipboard never lands in the history it displays.
    private let monitor: ClipboardMonitor

    init(store: ClipboardHistoryStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
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
        let content = QuickPasteContent(entries: Array(store.entries.prefix(Self.visibleEntryCount)))
        pendingText = content.committedEntry?.text

        hidePanel()
        let panel = QuickPastePanel(content: content)
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
            log.info("quick-paste committed with an empty clipboard history")
            return
        }

        // Silenced before the swap and re-baselined on resume afterwards. Without this the
        // swap-and-restore — two moves of the change counter — would be recorded as two
        // fresh copies, and the popup would pollute the very list it shows.
        monitor.suspend()
        Task { @MainActor [outputRouter, monitor] in
            // The existing clipboard-output path: snapshot, substitute, synthesise ⌘V,
            // restore. Reused unchanged and in the configuration that leaves the
            // clipboard as it was.
            await outputRouter.deliver(
                text: text,
                settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
            )
            monitor.resume()
        }
    }
}
