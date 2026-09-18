import AppKit
import SwiftUI
import ErrorToast
import os

@MainActor
final class ToastWindow: NSPanel {
    private static let log = Logger(subsystem: "WhisperKey", category: "ToastWindow")
    /// Distance from the right edge of the screen, and from the bottom of the menu bar,
    /// to the card itself. The window is `ToastView.margin` larger on every side than
    /// the card, for the close button that overhangs its corner, and that margin is
    /// taken off here so the card lands where these numbers say.
    private static let horizontalInset: CGFloat = max(12 - ToastView.margin, 0)
    private static let verticalInset: CGFloat = max(8 - ToastView.margin, 0)

    private var hostingView: NSHostingView<ToastView>!

    init(
        content: ToastContent,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ToastView.frameWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        // The card draws its own shadow, inside the window's transparent margin; a window
        // shadow on top of it would outline the margin, not the card.
        hasShadow = false
        // `.floating`, not `.statusBar`: above ordinary windows, but below the menus and
        // Control Center panels that drop down from the menu bar. A banner that sat above
        // them covered the Wi-Fi panel the user had just opened. The system's own
        // notification banners are covered by those panels the same way.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false

        let view = ToastView(
            content: content,
            onAction: onAction,
            onDismiss: onDismiss
        )
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = HoverReportingView(frame: contentRect(forFrameRect: frame))
        container.onHoverChanged = onHoverChanged
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
        setContentSize(NSSize(width: ToastView.frameWidth, height: max(56, fitting.height)))
    }

    /// The screen the pointer is on, because that is the one the user is looking at.
    /// `NSScreen.main` is the screen with the key window, and an accessory app that never
    /// activates has no say in which one that is.
    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// Where the toast rests: the top-right corner of the visible area, under the menu bar.
    private static func restingOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - size.width - horizontalInset,
            y: visible.maxY - size.height - verticalInset
        )
    }

    /// Slides in from the right edge of the screen to the resting position.
    ///
    /// The frame is animated with `animator().setFrame(_:display:)`, the one frame
    /// animation `NSWindow` documents. `setFrameOrigin` through the animator is not
    /// one, and the first build that used it never showed the window at all.
    func slideIn(duration: TimeInterval) {
        guard let screen = Self.screenUnderPointer() else {
            Self.log.error("slideIn: no screen; ordering front where the window is")
            orderFrontRegardless()
            return
        }
        let size = frame.size
        let resting = NSRect(origin: Self.restingOrigin(size: size, on: screen), size: size)
        let offscreen = NSRect(origin: NSPoint(x: screen.frame.maxX, y: resting.minY), size: size)

        setFrame(offscreen, display: false)
        alphaValue = 1
        // `orderFrontRegardless` rather than `orderFront`: an accessory app that never
        // activates has its plain `orderFront` ignored.
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(resting, display: true)
        }, completionHandler: {
            Task { @MainActor in
                Self.log.info("slideIn done frame=\(String(describing: self.frame), privacy: .public) visible=\(self.isVisible, privacy: .public) screen=\(String(describing: self.screen?.frame), privacy: .public)")
            }
        })
        Self.log.info("slideIn start screen=\(String(describing: screen.frame), privacy: .public) visibleFrame=\(String(describing: screen.visibleFrame), privacy: .public) from=\(String(describing: offscreen), privacy: .public) to=\(String(describing: resting), privacy: .public) visible=\(self.isVisible, privacy: .public)")
    }

    /// Slides back out past the right edge of the screen it is on.
    func slideOut(duration: TimeInterval, completion: @escaping @Sendable () -> Void) {
        let edge = (screen ?? Self.screenUnderPointer())?.frame.maxX ?? frame.maxX
        let offscreen = NSRect(origin: NSPoint(x: edge, y: frame.minY), size: frame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrame(offscreen, display: true)
            self.animator().alphaValue = 0
        }, completionHandler: completion)
    }
}

/// Reports when the pointer enters or leaves its bounds. The toast's timer pauses while
/// the pointer is over it, so a banner is not pulled away from under a hand reaching for
/// its button.
private final class HoverReportingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
