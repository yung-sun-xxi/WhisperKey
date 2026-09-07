import AppKit
import ClipboardHistoryStore
import SwiftUI

/// What the quick-paste panel shows: the most recent clipboard entries, newest first.
///
/// The entries come from `ClipboardHistoryStore`, not from a live read of the pasteboard.
/// Picking one of them by pointing is the next slice; this one still commits the newest.
struct QuickPasteContent: Equatable {
    /// Newest first, already trimmed to what the panel should display.
    let entries: [ClipboardEntry]

    var isEmpty: Bool { entries.isEmpty }

    /// The entry the gesture commits. Selection is unchanged from the previous slice —
    /// releasing takes the newest entry, which is what the clipboard itself held.
    var committedEntry: ClipboardEntry? { entries.first }
}

struct QuickPasteRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.origin == .whisperKey ? "waveform" : "doc.on.clipboard")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(entry.preview(maxLength: 80))
                .font(.system(size: 12))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
    }
}

struct QuickPasteView: View {
    static let contentWidth: CGFloat = 320

    let content: QuickPasteContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            if content.isEmpty {
                Text("Clipboard history is empty")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            } else {
                ForEach(content.entries) { entry in
                    QuickPasteRow(entry: entry, isSelected: entry.id == content.committedEntry?.id)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
        .frame(width: Self.contentWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
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
/// part in hit-testing and cannot be clicked even deliberately.
@MainActor
final class QuickPastePanel: NSPanel {
    private var hostingView: NSHostingView<QuickPasteView>!

    init(content: QuickPasteContent) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: QuickPasteView.contentWidth, height: 48),
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

        sizeToFitContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func sizeToFitContent() {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        setContentSize(NSSize(width: QuickPasteView.contentWidth, height: max(40, fitting.height)))
    }

    /// Screen-space origin for a panel of `size` shown under `cursor`, kept whole inside
    /// `visibleFrame`. Screen coordinates, so y grows upwards and "under the cursor"
    /// means a *lower* y.
    static func origin(cursor: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        let gap: CGFloat = 10
        let x = min(max(cursor.x - 16, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(cursor.y - size.height - gap, visibleFrame.minY), visibleFrame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    func show(at cursor: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(Self.origin(cursor: cursor, size: frame.size, visibleFrame: visible))
        }
        orderFrontRegardless()
    }
}
