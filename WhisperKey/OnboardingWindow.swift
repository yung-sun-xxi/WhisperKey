import AppKit
import AVFoundation
import Combine
import SwiftUI
import ThemeKit

/// The permissions onboarding window.
///
/// The look is ThemeKit's (#186): `ThemedPermissionsView` in the shared small-window
/// chrome, `ThemedSurfaceWindow`, which follows the theme while the window is open. This
/// file maps the coordinator's permissions onto the view and keeps the window's
/// behaviour: its z-order, when it shows and when it closes.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private var window: NSWindow?
    private var themeFollower: AnyCancellable?
    private var zOrderState: PermissionWindowZOrderState = .aboveOrdinaryApps
    private var userExplicitlyClosed = false
    private var closingForGrantedPermissions = false

    var relatedWindow: NSWindow? {
        window
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func sync(
        with permissions: PermissionState,
        forceShow: Bool,
        zOrderState: PermissionWindowZOrderState
    ) {
        if permissions.allGranted {
            closeForGrantedPermissions()
            return
        }

        if window != nil {
            applyZOrder(zOrderState, bringToFront: forceShow)
            return
        }

        self.zOrderState = zOrderState
        guard forceShow, !userExplicitlyClosed else { return }
        show(zOrderState: zOrderState)
    }

    func applyZOrder(_ state: PermissionWindowZOrderState, bringToFront: Bool) {
        let previousState = zOrderState
        zOrderState = state
        guard let window else { return }

        switch state {
        case .aboveOrdinaryApps, .yieldingToMicrophonePrompt:
            window.level = .floating
            if bringToFront {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        case .yieldingToAccessibilityPrompt, .yieldingToSystemSettings:
            window.level = .normal
            if previousState != state {
                window.orderBack(nil)
            }
        }
    }

    private func show(zOrderState: PermissionWindowZOrderState) {
        if window != nil {
            applyZOrder(zOrderState, bringToFront: zOrderState == .aboveOrdinaryApps)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        ThemeTokensSource.shared.follow(coordinator.settings)
        let window = Self.makeWindow(
            LivePermissionsView()
                .environmentObject(coordinator)
        )
        window.delegate = self
        themeFollower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)
        center(window)
        self.window = window
        applyZOrder(zOrderState, bringToFront: zOrderState == .aboveOrdinaryApps)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window as drawn, not yet placed or shown: `content` at its fitting size, in the
    /// surface chrome with the current theme. Shared with the Debug build's snapshot hook,
    /// which passes a view of fixed states.
    static func makeWindow(_ content: some View) -> NSWindow {
        let hostingView = NSHostingView(rootView: ThemedRoot("permissions") { content })
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperKey Permissions"
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)
        return window
    }

    /// What each card's button does.
    struct PermissionActions {
        var microphone: () -> Void
        var accessibility: () -> Void
    }

    /// The drawn view for `permissions`. The microphone card offers "Allow Microphone"
    /// until macOS has asked, "Open System Settings" after; the accessibility card always
    /// "Open System Settings".
    static func permissionsView(for permissions: PermissionState, actions: PermissionActions) -> ThemedPermissionsView {
        ThemedPermissionsView(
            microphone: .init(
                isGranted: permissions.microphoneGranted,
                buttonTitle: permissions.microphoneStatus == .notDetermined
                    ? "Allow Microphone"
                    : "Open System Settings",
                action: actions.microphone
            ),
            accessibility: .init(
                isGranted: permissions.accessibilityGranted,
                buttonTitle: "Open System Settings",
                action: actions.accessibility
            )
        )
    }

    private func closeForGrantedPermissions() {
        userExplicitlyClosed = false
        guard let window else { return }

        closingForGrantedPermissions = true
        window.close()
        closingForGrantedPermissions = false
        self.window = nil
    }

    private func center(_ window: NSWindow) {
        let frame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        if !closingForGrantedPermissions {
            userExplicitlyClosed = true
        }
        window = nil
        themeFollower = nil
    }
}

/// The window's content: the coordinator's permissions as they are now, redrawn when they
/// change.
private struct LivePermissionsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        OnboardingWindowController.permissionsView(for: coordinator.permissions, actions: actions)
    }

    /// The microphone button asks while macOS has not, and opens its pane otherwise,
    /// decided when it is tapped.
    private var actions: OnboardingWindowController.PermissionActions {
        OnboardingWindowController.PermissionActions(
            microphone: microphoneAction,
            accessibility: coordinator.openAccessibilitySettings
        )
    }

    private func microphoneAction() {
        if coordinator.permissions.microphoneStatus == .notDetermined {
            coordinator.requestMicrophonePermission()
        } else {
            coordinator.openMicrophoneSettings()
        }
    }
}
