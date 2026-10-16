import AppKit
import Combine
import os
import SwiftUI
import ThemeKit

/// The first-launch welcome window.
///
/// The look is ThemeKit's (#185): `ThemedWelcomeView` in the shared small-window chrome,
/// `ThemedSurfaceWindow`, which follows the theme while the window is open. This file
/// keeps the window's behaviour.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private static let log = Logger(subsystem: "WhisperKey", category: "WelcomeWindow")

    private let coordinator: AppCoordinator
    private var window: NSWindow?
    private var themeFollower: AnyCancellable?
    private var completingFromAction = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            Self.log.info("show existing welcome window visible=\(window.isVisible, privacy: .public)")
            present(window)
            return
        }

        Self.log.info("creating welcome window")
        ThemeTokensSource.shared.follow(coordinator.settings)
        let window = Self.makeWindow(
            goToSettings: { [weak self] in
                self?.complete(openSettings: true)
            },
            doLater: { [weak self] in
                self?.complete(openSettings: false)
            }
        )
        window.delegate = self
        themeFollower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)
        center(window)
        self.window = window
        present(window)
    }

    /// The window as drawn, not yet placed or shown: the content at the drawn view's
    /// fitting size, in the surface chrome with the current theme. Shared with the Debug
    /// build's snapshot hook, which passes its own actions.
    static func makeWindow(goToSettings: @escaping () -> Void, doLater: @escaping () -> Void) -> NSWindow {
        let hostingView = NSHostingView(rootView: ThemedRoot("welcome") {
            ThemedWelcomeView(goToSettings: goToSettings, doLater: doLater)
        })
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WhisperKey"
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        return window
    }

    func close() {
        window?.close()
    }

    private func complete(openSettings: Bool) {
        completingFromAction = true
        coordinator.completeWelcome(openSettings: openSettings)
        completingFromAction = false
    }

    private func center(_ window: NSWindow) {
        let frame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func present(_ window: NSWindow) {
        Self.log.info("present welcome window begin active=\(NSApp.isActive, privacy: .public) visible=\(window.isVisible, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            Self.log.info("present welcome window deferred active=\(NSApp.isActive, privacy: .public) visible=\(window.isVisible, privacy: .public) isKey=\(window.isKeyWindow, privacy: .public)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        Self.log.info("welcome window will close completingFromAction=\(self.completingFromAction, privacy: .public)")
        window = nil
        themeFollower = nil

        if !completingFromAction {
            coordinator.completeWelcome(openSettings: false)
        }
    }
}
