import AppKit
import SwiftUI

/// A window's chrome in the current theme (#162; reused by the other windows of #105).
///
/// `.system` (Classic) is the standard titled window: the system titlebar and title, and
/// the appearance the system gives it. `.drawn` (Midnight) makes the window dark — so
/// its menus, pop-ups and alerts are dark too — hides the system title and lets the
/// content run under a transparent titlebar, where the window draws `ThemedTitleBar`.
/// The traffic lights stay the system's, moved down to the middle of that taller bar.
///
/// Keep one instance per window and call `apply(_:background:)` whenever the tokens
/// change; it can switch either way while the window is open.
@MainActor
public final class ThemedWindowChrome {
    private weak var window: NSWindow?
    private var barHeight: CGFloat?
    private var observers: [NSObjectProtocol] = []

    public init(window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeTrafficLights() }
            })
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func apply(_ tokens: ThemeTokens, background: ThemeColor) {
        guard let window else { return }

        window.backgroundColor = background.nsColor
        switch tokens.windowChrome {
        case .system:
            barHeight = nil
            window.appearance = nil
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
            restoreTrafficLights()
        case .drawn:
            barHeight = tokens.sizes.titlebar
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            placeTrafficLights()
            // AppKit lays the titlebar out again after a style change; follow it.
            DispatchQueue.main.async { [weak self] in
                self?.placeTrafficLights()
            }
        }
    }

    /// Re-centres the traffic lights after the window changed size or style.
    public func placeTrafficLights() {
        guard let barHeight else { return }
        centreTrafficLights(inBarOfHeight: barHeight)
    }

    private func centreTrafficLights(inBarOfHeight barHeight: CGFloat) {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebarView = close.superview,
              let container = titlebarView.superview
        else { return }

        var containerFrame = container.frame
        containerFrame.size.height = barHeight
        containerFrame.origin.y = window.frame.height - barHeight
        if container.frame != containerFrame {
            container.frame = containerFrame
        }
        titlebarView.frame = container.bounds

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            var frame = button.frame
            // Centred: the same offset from the top and from the bottom.
            frame.origin.y = (barHeight - frame.height) / 2
            if button.frame.origin.y != frame.origin.y {
                button.setFrameOrigin(frame.origin)
            }
        }
    }

    /// Back from `.drawn`: the titlebar container is put back to the system titlebar's
    /// height, the part of the frame the content no longer covers.
    private func restoreTrafficLights() {
        guard let window else { return }
        let systemBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        guard systemBar > 0 else { return }
        centreTrafficLights(inBarOfHeight: systemBar)
    }
}

/// The bar `.drawn` chrome draws where the titlebar was: `sizes.titlebar` tall on `bar`,
/// the title centred in `type.title` and `primaryText`. Draws nothing for `.system`.
public struct ThemedTitleBar: View {
    @Environment(\.themeTokens) private var tokens
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        if tokens.windowChrome == .drawn {
            Text(title)
                .font(tokens.type.title.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: tokens.sizes.titlebar)
                .background(tokens.colors.bar.color)
                .accessibilityHidden(true)
        }
    }
}
