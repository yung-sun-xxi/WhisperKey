import AppKit
import ClipboardHistoryStore
import Foundation
import HotkeyEngine
import PasteEngine
import QuickPaste
import os

/// The quick-paste popup: hold the trigger, a non-activating panel appears under the
/// cursor listing the most recent clipboard entries, point at one, release, and it is
/// pasted where the caret still is. Releasing over none of them cancels.
///
/// Whether any of it runs is not decided here. `QuickPasteActivation` owns that, from the
/// settings and the Accessibility permission, and calls `start()` and `stop()` — which is
/// what makes "off means off" provable in `swift test` instead of by eye. With the
/// feature off this object still exists, but its event tap does not: `stop()` tears the
/// tap down, so no key is intercepted for it.
///
/// This file is deliberately thin, because the application target has no test bundle: the
/// gesture is in `HoldToRevealStateMachine`, the event translation in `HoldToRevealRunner`,
/// and every piece of geometry — panel size, placement, which row a point is in — in
/// `QuickPasteLayout`. What is left here is the parts that only exist against a live
/// system: a timer, an `NSPanel`, `NSEvent.mouseLocation` and `NSWorkspace`.
@MainActor
final class QuickPasteController: QuickPasteGestureControlling {
    /// How often the highlight is repainted while the panel is open. Display only — a
    /// coarser interval would show a stale highlight, never paste the wrong entry.
    private static let highlightInterval: TimeInterval = 1.0 / 60.0

    /// What is on screen right now, and what the world looked like when it appeared.
    private struct Reveal {
        let entryCount: Int
        let frame: CGRect
        let isFlipped: Bool
        /// The application that was in front when the threshold fired. Anything else in
        /// front at release time means the text would land somewhere the user was not
        /// looking when the gesture began.
        let targetProcessIdentifier: Int32?
    }

    private let log = Logger(subsystem: "WhisperKey", category: "QuickPaste")
    private let runner: HoldToRevealRunner
    private let outputRouter = TranscriptionOutputRouter()
    private var machine: HoldToRevealStateMachine
    /// The trigger, the hold and the entry count, as the settings currently have them.
    private var configuration: QuickPasteConfiguration
    private var panel: QuickPastePanel?
    private var holdTimer: Timer?
    private var highlightTimer: Timer?
    private var reveal: Reveal?
    private var revealedEntries: [ClipboardEntry] = []
    private var started = false

    /// The history the panel renders. Filled by `ClipboardMonitor`, not read live off the
    /// pasteboard.
    private let store: ClipboardHistoryStore
    /// Silenced around this controller's own clipboard swap, so the popup's temporary use
    /// of the clipboard never lands in the history it displays.
    private let monitor: ClipboardMonitor

    init(
        store: ClipboardHistoryStore,
        monitor: ClipboardMonitor,
        configuration: QuickPasteConfiguration = QuickPasteConfiguration()
    ) {
        self.store = store
        self.monitor = monitor
        self.configuration = configuration
        self.runner = HoldToRevealRunner(trigger: configuration.trigger)
        self.machine = HoldToRevealStateMachine(holdThreshold: configuration.holdDuration)

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

    /// Called when the gesture has something to say — in practice, when the paste was
    /// refused. Set by `AppCoordinator`, which owns the toast.
    ///
    /// A closure rather than a `ToastPresenter` held here, because *whether* to speak is
    /// `QuickPasteFeedback.notice(for:)` in the package, and *how* to speak is the
    /// application's one toast. This object is left with neither decision.
    var onNotice: ((QuickPasteNotice) -> Void)?

    var isRunning: Bool { started }

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

    /// Takes a new trigger, hold duration and entry count while the app is running.
    ///
    /// The state machine's threshold is a `let`, so a changed hold duration rebuilds it —
    /// carrying the application state across, because a machine that forgot a recording
    /// was in flight would let the panel open on top of it. Any gesture in progress is
    /// abandoned, which is the right answer while the user is in Settings anyway.
    func apply(configuration: QuickPasteConfiguration) {
        guard configuration != self.configuration else { return }
        let appState = machine.appState
        self.configuration = configuration
        runner.setTrigger(configuration.trigger)
        cancelHoldTimer()
        hidePanel()
        machine = HoldToRevealStateMachine(
            holdThreshold: configuration.holdDuration,
            appState: appState
        )
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
        let threshold = configuration.holdDuration
        let timer = Timer(timeInterval: threshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdTimer = nil
                self.apply(
                    self.machine.process(
                        .holdThresholdElapsed(at: pressedAt + threshold)
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
            hidePanel()
        case .commit:
            commit()
        }
    }

    // MARK: - Showing the panel

    private func revealPanel() {
        hidePanel()

        let entries = Array(store.entries.prefix(configuration.visibleEntryCount))
        let cursor = NSEvent.mouseLocation
        let size = QuickPasteLayout.panelSize(entryCount: entries.count)
        let placement = QuickPasteLayout.placement(
            cursor: cursor,
            size: size,
            visibleFrame: Self.visibleFrame(containing: cursor)
        )

        let content = QuickPasteContent(entries: entries, isFlipped: placement.isFlipped)
        let panel = QuickPastePanel(content: content)
        panel.show(at: placement.origin)
        self.panel = panel
        self.revealedEntries = entries
        self.reveal = Reveal(
            entryCount: entries.count,
            frame: CGRect(origin: placement.origin, size: size),
            isFlipped: placement.isFlipped,
            targetProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )

        startHighlightTimer()
    }

    /// The visible area of the display the cursor is actually on, so the panel never
    /// opens on the wrong monitor. `NSScreen.main` is the screen with the key window,
    /// which for an accessory app with no windows is not necessarily where the mouse is.
    private static func visibleFrame(containing cursor: NSPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func startHighlightTimer() {
        highlightTimer?.invalidate()
        let timer = Timer(timeInterval: Self.highlightInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repaintHighlight()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    private func repaintHighlight() {
        guard let reveal, let panel else { return }
        panel.setHighlightedIndex(Self.index(at: NSEvent.mouseLocation, in: reveal))
    }

    private static func index(at mouse: NSPoint, in reveal: Reveal) -> Int? {
        QuickPasteLayout.highlightedIndex(
            mouse: mouse,
            panelFrame: reveal.frame,
            entryCount: reveal.entryCount,
            isFlipped: reveal.isFlipped
        )
    }

    private func hidePanel() {
        highlightTimer?.invalidate()
        highlightTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        reveal = nil
        revealedEntries = []
    }

    // MARK: - Choosing

    /// Resolves the chosen entry from a mouse position read *now*, at the moment the key
    /// release arrived — not from whatever the highlight timer last sampled. A fast move
    /// followed by a release would otherwise commit the neighbouring row, or none.
    private func commit() {
        guard let reveal else {
            hidePanel()
            return
        }

        let index = Self.index(at: NSEvent.mouseLocation, in: reveal)
        let entries = revealedEntries
        let target = reveal.targetProcessIdentifier

        hidePanel()

        guard let index, index < entries.count else {
            // Released over no entry. This is the gesture's only cancel: nothing pasted,
            // nothing written to the clipboard, and no error — backing out is the same
            // motion as choosing.
            log.info("quick-paste released over no entry; nothing pasted")
            return
        }

        guard QuickPasteTargetGuard.shouldPaste(
            captured: target,
            current: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else {
            log.info("quick-paste target application changed during the hold; nothing pasted")
            return
        }

        paste(entries[index].text)
    }

    private func paste(_ text: String) {
        guard !text.isEmpty else {
            log.info("quick-paste committed an empty entry")
            return
        }

        // Silenced before the swap and re-baselined on resume afterwards. Without this the
        // swap-and-restore — two moves of the change counter — would be recorded as two
        // fresh copies, and the popup would pollute the very list it shows.
        monitor.suspend()
        Task { @MainActor [weak self, outputRouter, monitor] in
            // The existing clipboard-output path: snapshot, substitute, synthesise ⌘V,
            // restore. Reused unchanged and in the configuration that leaves the
            // clipboard as it was.
            let result = await outputRouter.deliver(
                text: text,
                settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true)
            )
            monitor.resume()
            self?.report(result)
        }
    }

    /// Turns the outcome of the paste into a word to the user, or into silence.
    ///
    /// The case that matters is `PasteEngine` declining because a secure field is
    /// focused: the router restores the clipboard afterwards, so without this the user's
    /// deliberate choice produces nothing at all — nothing pasted, and nothing left on
    /// the clipboard to paste by hand.
    private func report(_ result: TranscriptionOutputResult) {
        guard let notice = QuickPasteFeedback.notice(for: result) else { return }
        log.info("quick-paste notice=\(String(describing: notice), privacy: .public)")
        onNotice?(notice)
    }
}
