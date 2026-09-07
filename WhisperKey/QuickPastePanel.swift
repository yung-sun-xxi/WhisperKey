import AppKit
import ClipboardHistoryStore
import QuickPaste
import SwiftUI

/// What the quick-paste panel shows: the most recent clipboard entries, and which of them
/// the pointer is currently over.
///
/// The entries come from `ClipboardHistoryStore`, not from a live read of the pasteboard.
/// Which one is chosen is decided by `QuickPasteLayout` from the mouse position, never by
/// the view — the panel takes no mouse events at all.
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

struct QuickPasteRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    /// Dictated and hand-copied entries differ by shape *and* by colour, so five similar
    /// fragments can be told apart without reading them. Shape alone is an 11-point glyph
    /// at the edge of a row; colour alone would be lost on a monochrome display or to a
    /// colour-blind eye.
    private var isDictated: Bool { entry.origin == .whisperKey }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isDictated ? "waveform" : "doc.on.clipboard")
                .font(.system(size: 11, weight: isDictated ? .semibold : .regular))
                .foregroundStyle(isDictated ? Color.accentColor : Color.secondary)
                .frame(width: 14)
                .accessibilityLabel(isDictated ? "Dictated" : "Copied")
            Text(entry.preview(maxLength: QuickPasteLayout.previewLength))
                .font(.system(size: 12))
                .foregroundStyle(Color.primary)
                // One line, cut at the tail. Together with the fixed width below this is
                // what stops a long entry widening or wrapping the panel — the window is
                // sized from `QuickPasteLayout`, so text that wanted more room would be
                // clipped rather than granted it.
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        // A fixed height, because the hit test computes row bands from the same number.
        // A row that sized itself to its content would put the highlight and the choice
        // on different rows.
        .frame(height: QuickPasteLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
    }
}

struct QuickPasteView: View {
    let content: QuickPasteContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: QuickPasteLayout.headerHeight, alignment: .center)
                .padding(.bottom, QuickPasteLayout.headerBottomSpacing)
            if content.isEmpty {
                Text("Clipboard history is empty")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: QuickPasteLayout.rowHeight, alignment: .leading)
            } else {
                ForEach(content.displayOrder, id: \.entry.id) { row in
                    QuickPasteRow(
                        entry: row.entry,
                        isSelected: row.index == content.highlightedIndex
                    )
                }
            }
        }
        .padding(.horizontal, QuickPasteLayout.horizontalPadding)
        .padding(.vertical, QuickPasteLayout.verticalPadding)
        .frame(width: QuickPasteLayout.contentWidth, alignment: .leading)
        // `VisualEffectBackground` rather than SwiftUI's `.regularMaterial`, for the
        // reason spelled out on that type: a `Material` blends with what is inside the
        // window, and this window's background is `.clear`, so the material had nothing
        // to blend with and painted a flat opaque slab over whatever the panel covered.
        // `ToastView` has always used this; the panel now uses the same thing.
        //
        // Every colour here is semantic — `Color.primary`, `Color.secondary`,
        // `Color.accentColor` and an AppKit material — so light and dark are the
        // system's answer, not a palette of ours.
        .background { VisualEffectBackground(material: .popover) }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
/// position, and the window's own size and origin come from the same file — one geometry,
/// used by both the drawing and the choosing.
@MainActor
final class QuickPastePanel: NSPanel {
    private var hostingView: NSHostingView<QuickPasteView>!
    private var content: QuickPasteContent

    init(content: QuickPasteContent) {
        self.content = content
        let size = QuickPasteLayout.panelSize(entryCount: content.entries.count)
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
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: QuickPasteView(content: content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: contentRect(forFrameRect: frame))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
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
        hostingView.rootView = QuickPasteView(content: content)
    }

    /// Long enough to read as an appearance rather than a flash, short enough that the
    /// panel is fully there before a deliberate hold has finished settling. The same
    /// `fadeInOrderingFront` the toast uses.
    static let fadeDuration: TimeInterval = 0.12

    func show(at origin: NSPoint) {
        setFrameOrigin(origin)
        fadeInOrderingFront(duration: Self.fadeDuration)
    }
}
