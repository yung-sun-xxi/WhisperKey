import AppKit
import Live
import SwiftUI

/// What the island draws. The text and the state come from `LiveIsland`; this slice shows
/// the text alone, red for an error.
struct LiveIslandView: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(width: LiveIslandWindow.size.width, height: LiveIslandWindow.size.height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isError ? Color(red: 0.55, green: 0.08, blue: 0.08) : Color.black.opacity(0.88))
            )
    }
}

/// The Live island: a click-through panel at the top centre of the screen the pointer is on.
///
/// The window conventions are `QuickPastePanel`'s, which took them from `ToastWindow`: a
/// borderless `.nonactivatingPanel`, `.statusBar` level and `.fullScreenAuxiliary` so it
/// sits above a full-screen game, `canBecomeKey == false` so the game keeps the keyboard,
/// and `ignoresMouseEvents` so clicks go through it. It never activates the app.
@MainActor
final class LiveIslandWindow: NSPanel {
    static let size = NSSize(width: 296, height: 72)
    private static let topInset: CGFloat = 8
    private static let fadeDuration: TimeInterval = 0.12

    private let hostingView: NSHostingView<LiveIslandView>

    init() {
        hostingView = NSHostingView(rootView: LiveIslandView(text: "", isError: false))
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        isReleasedWhenClosed = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        setContentSize(Self.size)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Applies one `.island` command from the session.
    func apply(_ island: LiveIsland) {
        switch island {
        case .hidden:
            hide()
        case .shown(let state, let text):
            let isError: Bool
            if case .error = state { isError = true } else { isError = false }
            hostingView.rootView = LiveIslandView(text: text, isError: isError)
            show()
        }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }

    private func show() {
        guard !isVisible else { return }
        setFrameOrigin(Self.origin(on: Self.screenUnderPointer()))
        fadeInOrderingFront(duration: Self.fadeDuration)
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    /// Top centre of the visible frame: below the menu bar when there is one, at the very
    /// top over a full-screen app, where the visible frame is the whole screen.
    private static func origin(on screen: NSScreen?) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - topInset
        )
    }
}
