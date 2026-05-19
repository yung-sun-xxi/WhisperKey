import AppKit
import os
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private static let log = Logger(subsystem: "WhisperKey", category: "WelcomeWindow")

    private let coordinator: AppCoordinator
    private var window: NSWindow?
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
        let content = WelcomeView(
            goToSettings: { [weak self] in
                self?.complete(openSettings: true)
            },
            doLater: { [weak self] in
                self?.complete(openSettings: false)
            }
        )
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 148),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WhisperKey"
        window.contentView = hostingView
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        center(window)
        self.window = window
        present(window)
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

        if !completingFromAction {
            coordinator.completeWelcome(openSettings: false)
        }
    }
}

private struct WelcomeView: View {
    let goToSettings: () -> Void
    let doLater: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            VStack(alignment: .center, spacing: 8) {
                Text("Welcome to WhisperKey!")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Go to Settings to set up your preferences, or you can do it later")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack {
                Button("Go to Settings", action: goToSettings)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Later", action: doLater)
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .frame(width: 390, height: 148)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
