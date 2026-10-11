import AppKit
import SwiftUI

/// A window's chrome in the current theme (#162; reused by the other windows of #105).
///
/// One style mask in both themes: the content always runs under a transparent titlebar
/// (`.fullSizeContentView`), so the frame is the content and a theme switch never
/// changes the mask, which would make AppKit move or resize the window. The window draws
/// `ThemedTitleBar` at the top of its content in either theme.
///
/// `.system` (Classic) looks like the standard titled window: the system appearance, the
/// system title text and the traffic lights where the system puts them, over an empty
/// band in the window's background colour. `.drawn` (Midnight) makes the window dark — so
/// its menus, pop-ups and alerts are dark too — hides the system title, and moves the
/// traffic lights down to the middle of its taller drawn bar.
///
/// Keep one instance per window and call `apply(_:background:)` whenever the tokens
/// change; it can switch either way while the window is open.
@MainActor
public final class ThemedWindowChrome {
    private weak var window: NSWindow?
    private var barHeight: CGFloat?
    private var observers: [NSObjectProtocol] = []

    /// Sets the one style mask both themes share. Inserting `.fullSizeContentView` keeps
    /// the content rect and shrinks the frame by the titlebar, so do it before the
    /// window is sized and placed.
    public init(window: NSWindow) {
        self.window = window
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true

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

    /// Colours, appearance, title and traffic lights. Never the style mask.
    public func apply(_ tokens: ThemeTokens, background: ThemeColor) {
        guard let window else { return }

        window.backgroundColor = background.nsColor
        switch tokens.windowChrome {
        case .system:
            barHeight = nil
            window.appearance = nil
            window.titleVisibility = .visible
            restoreTrafficLights()
        case .drawn:
            barHeight = tokens.sizes.titlebar
            window.appearance = NSAppearance(named: .darkAqua)
            window.titleVisibility = .hidden
            placeTrafficLights()
            // AppKit lays the titlebar out again on the next pass; follow it.
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
    /// height. The content covers the whole frame, so that height is not the frame less
    /// the content rect; it is what the same mask without `.fullSizeContentView` would
    /// add above the content.
    private func restoreTrafficLights() {
        guard let window else { return }
        let content = NSRect(origin: .zero, size: window.frame.size)
        let titled = NSWindow.frameRect(
            forContentRect: content,
            styleMask: window.styleMask.subtracting(.fullSizeContentView)
        )
        let systemBar = titled.height - content.height
        guard systemBar > 0 else { return }
        centreTrafficLights(inBarOfHeight: systemBar)
    }
}

/// The bar at the top of a themed window's content, `sizes.titlebar` tall, under the
/// transparent system titlebar. `.drawn`: the title centred in `type.title` and
/// `primaryText` on `bar`. `.system`: an empty band in the window's background colour
/// (it is clear), over which the system draws its own title and traffic lights.
public struct ThemedTitleBar: View {
    @Environment(\.themeTokens) private var tokens
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        switch tokens.windowChrome {
        case .drawn:
            Text(title)
                .font(tokens.type.title.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: tokens.sizes.titlebar)
                .background(tokens.colors.bar.color)
                .accessibilityHidden(true)
        case .system:
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: tokens.sizes.titlebar)
                .accessibilityHidden(true)
        }
    }
}
