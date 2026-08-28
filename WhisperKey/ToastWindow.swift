import AppKit
import SwiftUI
import ErrorToast

@MainActor
final class ToastWindow: NSPanel {
    private var hostingView: NSHostingView<ToastView>!

    init(
        content: ToastContent,
        anchor: NSRect?,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ToastView.contentWidth, height: 80),
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
        ignoresMouseEvents = false

        let view = ToastView(
            content: content,
            pointerCenterX: Self.pointerCenterX(for: anchor),
            onAction: onAction,
            onDismiss: onDismiss
        )
        let hosting = NSHostingView(rootView: view)
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
        setContentSize(NSSize(width: ToastView.contentWidth, height: max(56, fitting.height)))
    }

    func position(anchor: NSRect?) {
        if let anchor {
            positionBelowMenuBarItem(anchor)
            return
        }

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.maxY - size.height - 8
        )
        setFrameOrigin(origin)
    }

    private func positionBelowMenuBarItem(_ anchor: NSRect) {
        guard let origin = Self.originBelowMenuBarItem(anchor, size: frame.size) else { return }
        setFrameOrigin(origin)
    }

    private static func pointerCenterX(for anchor: NSRect?) -> CGFloat? {
        guard let anchor,
              let origin = originBelowMenuBarItem(
                  anchor,
                  size: NSSize(width: ToastView.contentWidth, height: 0)
              )
        else { return nil }

        return min(
            max(anchor.midX - origin.x, 26),
            ToastView.contentWidth - 26
        )
    }

    private static func originBelowMenuBarItem(_ anchor: NSRect, size: NSSize) -> NSPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else {
            return nil
        }

        let visible = screen.visibleFrame
        let horizontalInset: CGFloat = 6
        let preferredPointerCenterX: CGFloat = 46
        let x = min(
            max(anchor.midX - preferredPointerCenterX, visible.minX + horizontalInset),
            visible.maxX - size.width - horizontalInset
        )
        return NSPoint(x: x, y: visible.maxY - size.height)
    }

    func fadeIn(duration: TimeInterval, anchor: NSRect?) {
        alphaValue = 0
        position(anchor: anchor)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
        }
    }

    func fadeOut(duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 0.0
        }, completionHandler: completion)
    }
}
