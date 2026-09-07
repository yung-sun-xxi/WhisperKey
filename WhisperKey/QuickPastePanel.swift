import AppKit
import SwiftUI

/// What the quick-paste panel shows. One entry for now — the tracer bullet carries a
/// single clipboard string, not a history.
struct QuickPasteContent: Equatable {
    let text: String?

    var preview: String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Clipboard is empty"
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    var hasText: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }
}

struct QuickPasteView: View {
    static let contentWidth: CGFloat = 320

    let content: QuickPasteContent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content.preview)
                .font(.system(size: 12))
                .foregroundStyle(content.hasText ? Color.primary : Color.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
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
