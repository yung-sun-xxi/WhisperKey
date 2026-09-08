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
/// gesture is in `HoldToRevealStateMachine`, the event translation and the decision to
/// swallow an arrow in `HoldToRevealRunner`, every piece of geometry — panel size,
/// placement, which row a point is in — in `QuickPasteLayout`, and which row the pointer
/// and the arrow keys between them have chosen in `QuickPasteSelection`. What is left
/// here is the parts that only exist against a live system: a timer, an `NSPanel`,
/// `NSEvent.mouseLocation` and `NSWorkspace`.
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
        /// Which row is chosen and which input chose it. The pointer and the arrow keys
        /// both write here, and `QuickPasteSelection` is what decides which of them wins.
        var selection: QuickPasteSelection
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
        case .otherModifierUp, .holdThresholdElapsed, .arrowKeyDown:
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
        case .moveSelection(let direction):
            moveSelection(direction)
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
            selection: QuickPasteSelection(
                entryCount: entries.count,
                isFlipped: placement.isFlipped
            ),
            targetProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )

        // From here on the tap swallows arrow keys instead of letting them through to the
        // application. Set before the first repaint, and cleared in `hidePanel`, so the
        // flag is never true with nothing on screen.
        runner.setRevealed(true)
        // The first reading, taken with the panel: it paints the row under the cursor
        // straight away, and it gives the selection a baseline to compare later readings
        // against, so an arrow pressed before the timer's first tick is not undone by it.
        repaintHighlight()
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

    /// Reads the mouse and offers it to the selection, which ignores it if the pointer
    /// has not actually moved since the last reading and the keyboard is steering.
    /// Returns whatever is selected afterwards.
    @discardableResult
    private func samplePointer() -> Int? {
        guard var reveal = self.reveal else { return nil }
        let mouse = NSEvent.mouseLocation
        let index = reveal.selection.pointerSampled(
            at: mouse,
            hitting: Self.index(at: mouse, in: reveal)
        )
        self.reveal = reveal
        return index
    }

    private func repaintHighlight() {
        panel?.setHighlightedIndex(samplePointer())
    }

    /// An arrow key arrived while the panel is up. The panel stays where it is; only the
    /// highlight moves, and the keyboard takes the selection over from the pointer.
    private func moveSelection(_ direction: HoldToRevealArrowDirection) {
        guard var reveal = self.reveal else { return }
        let index = reveal.selection.arrowPressed(direction)
        self.reveal = reveal
        panel?.setHighlightedIndex(index)
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
        // Arrow keys go back to the application the moment the panel is gone.
        runner.setRevealed(false)
        highlightTimer?.invalidate()
        highlightTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        reveal = nil
        revealedEntries = []
    }

    // MARK: - Choosing

    /// Resolves the chosen entry at the moment the key release arrived, not from whatever
    /// the highlight timer last painted.
    ///
    /// The mouse is read *now* and offered to the selection, so a fast move followed by a
    /// release still commits the row the pointer ended on rather than its neighbour. The
    /// selection ignores that reading when the pointer has not moved and the arrow keys
    /// are steering — which is what makes "release commits the row the keyboard chose".
    private func commit() {
        guard let open = reveal else {
            hidePanel()
            return
        }

        let target = open.targetProcessIdentifier
        let index = samplePointer()
        let entries = revealedEntries

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
            // restore. Reused in the configuration that leaves the clipboard as it was.
            //
            // The one thing this path is asked to do differently from the transcription
            // auto-paste is `QuickPastePolicy.secureFieldPolicy`: a password field is
            // pasted into, because the user pointed at the entry and released. The
            // transcription path passes nothing and keeps refusing.
            let result = await outputRouter.deliver(
                text: text,
                settings: TranscriptionOutputSettings(saveToClipboard: false, autoPaste: true),
                secureFieldPolicy: QuickPastePolicy.secureFieldPolicy
            )
            monitor.resume()
            self?.report(result)
        }
    }

    /// Turns the outcome of the paste into a word to the user, or into silence.
    ///
    /// The case that matters is `PasteEngine` declining: the router restores the
    /// clipboard afterwards, so without this the user's deliberate choice produces
    /// nothing at all — nothing pasted, and nothing left on the clipboard to paste by
    /// hand. Since the popup asks for `SecureFieldPolicy.allow`, a labelled password
    /// field is no longer one of those cases; what is left is a field the paste path
    /// could not identify while macOS secure input was on.
    private func report(_ result: TranscriptionOutputResult) {
        guard let notice = QuickPasteFeedback.notice(for: result) else { return }
        log.info("quick-paste notice=\(String(describing: notice), privacy: .public)")
        onNotice?(notice)
    }
}
