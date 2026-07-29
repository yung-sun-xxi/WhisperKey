import AppKit
import SwiftUI
import ErrorToast

@MainActor
final class ToastWindow: NSPanel {
    private var hostingView: NSHostingView<ToastView>!

    init(
        content: ToastContent,
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

        let view = ToastView(content: content, onAction: onAction, onDismiss: onDismiss)
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

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.maxY - size.height - 8
        )
        setFrameOrigin(origin)
    }

    func fadeIn(duration: TimeInterval) {
        alphaValue = 0
        positionTopRight()
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
