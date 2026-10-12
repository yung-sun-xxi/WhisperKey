import AppKit
import ClipboardHistoryStore
import QuickPaste
import SwiftUI
import ThemeKit

/// What the quick-paste panel shows: the most recent clipboard entries, and which of them
/// the pointer is currently over.
///
/// The entries come from `ClipboardHistoryStore`, not from a live read of the pasteboard.
/// Which one is chosen is decided by `QuickPasteLayout` from the mouse position, never by
/// the view — the panel takes no mouse events at all. `ThemedQuickPasteView` draws it.
struct QuickPasteContent: Equatable {
    /// Newest first, already trimmed to what the panel should display.
    let entries: [ClipboardEntry]
    /// Rows are drawn bottom-up when the panel had to open above the cursor, so the
    /// newest entry is the one next to the pointer either way.
    let isFlipped: Bool
    /// Index into `entries` — not into the rows on screen — of the entry under the
    /// pointer. `nil` means the pointer is over none of them, and releasing cancels.
    var highlightedIndex: Int?

    init(entries: [ClipboardEntry], isFlipped: Bool = false, highlightedIndex: Int? = nil) {
        self.entries = entries
        self.isFlipped = isFlipped
        self.highlightedIndex = highlightedIndex
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Entries in the order they appear from the top of the panel down.
    var displayOrder: [(index: Int, entry: ClipboardEntry)] {
        let numbered = Array(entries.enumerated()).map { (index: $0.offset, entry: $0.element) }
        return isFlipped ? numbered.reversed() : numbered
    }
}

extension QuickPasteContent {
    /// The rows as the themed view draws them, top down, and which one is selected.
    var rows: [ThemedQuickPasteView.Row] {
        displayOrder.map { row in
            ThemedQuickPasteView.Row(
                id: row.entry.id,
                text: row.entry.preview(maxLength: QuickPasteLayout.previewLength),
                marker: row.entry.origin == .whisperKey ? .dictated : .copied
            )
        }
    }

    var selectedID: UUID? {
        highlightedIndex.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
    }
}

/// A non-activating panel that appears under the cursor and never takes focus.
///
/// Built by following `ToastWindow`, which already solves this: the borderless
/// `.nonactivatingPanel` style mask, `isFloatingPanel`, `hidesOnDeactivate = false`,
/// `.statusBar` level and the `.canJoinAllSpaces` / `.fullScreenAuxiliary` collection
/// behaviour are load-bearing, not polish. WhisperKey is an accessory app with no
/// activation, so a panel at the normal window level sits *below* the frontmost
/// application, and without `.fullScreenAuxiliary` it does not appear over a full-screen
/// app at all — which is where this feature is meant to be used.
///
/// `canBecomeKey == false` is the single thing that keeps the caret blinking in the
/// user's own text field.
///
/// The one difference from `ToastWindow`: `ignoresMouseEvents = true`. The panel takes no
/// part in hit-testing and cannot be clicked even deliberately. Which row is highlighted
/// therefore comes from `QuickPasteLayout.highlightedIndex` applied to the global mouse
/// position, and the window's own size comes from the same file. The `metrics` it is
/// built with are the controller's, the same value the hit test takes — one geometry,
/// used by both the drawing and the choosing.
///
/// The look is the shared floating-panel shell (#105 rule 4, #166): `ThemedPanelChromeView`
/// as the window's content, `ThemedQuickPasteView` inside it.
@MainActor
final class QuickPastePanel: NSPanel {
    private var hostingView: NSHostingView<ThemedRoot<ThemedQuickPasteView>>!
    private var content: QuickPasteContent
    private let metrics: QuickPasteMetrics

    init(content: QuickPasteContent, metrics: QuickPasteMetrics) {
        self.content = content
        self.metrics = metrics
        let size = QuickPasteLayout.panelSize(
            entryCount: content.entries.count,
            metrics: metrics
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // Clear and see-through, with the window server's shadow: the shell's rounded
        // shape is the panel's outline.
        ThemedPanelChromeView.configure(self)
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: Self.root(content, metrics: metrics))
        contentView = ThemedPanelChromeView(kind: .quickPaste, contentView: hosting)
        self.hostingView = hosting

        // Sized from the layout rather than from `fittingSize`: the hit test derives row
        // bands from these same numbers, so the window must be exactly that tall.
        setContentSize(size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Repaints the highlight. Display only — what is actually chosen is resolved from a
    /// fresh mouse reading when the key comes up, never from this.
    func setHighlightedIndex(_ index: Int?) {
        guard content.highlightedIndex != index else { return }
        content.highlightedIndex = index
        hostingView.rootView = Self.root(content, metrics: metrics)
    }

    private static func root(
        _ content: QuickPasteContent,
        metrics: QuickPasteMetrics
    ) -> ThemedRoot<ThemedQuickPasteView> {
        ThemedRoot("quickPaste") {
            ThemedQuickPasteView(metrics: metrics, rows: content.rows, selectedID: content.selectedID)
        }
    }

    /// Long enough to read as an appearance rather than a flash, short enough that the
    /// panel is fully there before a deliberate hold has finished settling.
    static let fadeDuration: TimeInterval = 0.12

    func show(at origin: NSPoint) {
        setFrameOrigin(origin)
        fadeInOrderingFront(duration: Self.fadeDuration)
    }
}
