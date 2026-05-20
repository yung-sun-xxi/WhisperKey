import AppKit
import AVFoundation
import SwiftUI

private enum OnboardingWindowLayout {
    static let width: CGFloat = 520
}

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private var window: NSWindow?
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

        let content = OnboardingView()
            .environmentObject(coordinator)
        let hostingView = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: OnboardingWindowLayout.width, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperKey Permissions"
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        center(window)
        self.window = window
        applyZOrder(zOrderState, bringToFront: zOrderState == .aboveOrdinaryApps)
        NSApp.activate(ignoringOtherApps: true)
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
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WhisperKey needs permissions")
                    .font(.title2.weight(.semibold))
                Text("Grant both permissions to record from the menu bar hotkey.")
                    .foregroundStyle(.secondary)
            }

            PermissionCard(
                symbolName: "mic",
                title: "Microphone",
                message: "Used only while recording after the hotkey starts capture.",
                isGranted: coordinator.permissions.microphoneGranted,
                buttonTitle: microphoneButtonTitle,
                action: microphoneAction
            )

            PermissionCard(
                symbolName: "accessibility",
                title: "Accessibility",
                message: "Required for the global hotkey to work while other apps are focused.",
                isGranted: coordinator.permissions.accessibilityGranted,
                buttonTitle: "Open System Settings",
                action: coordinator.openAccessibilitySettings
            )
        }
        .padding(24)
        .frame(width: OnboardingWindowLayout.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var microphoneButtonTitle: String {
        coordinator.permissions.microphoneStatus == .notDetermined
            ? "Allow Microphone"
            : "Open System Settings"
    }

    private func microphoneAction() {
        if coordinator.permissions.microphoneStatus == .notDetermined {
            coordinator.requestMicrophonePermission()
        } else {
            coordinator.openMicrophoneSettings()
        }
    }
}

private struct PermissionCard: View {
    let symbolName: String
    let title: String
    let message: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.title2)
                .frame(width: 32, height: 32)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Label(isGranted ? "Granted" : "Needs access", systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isGranted ? .green : .orange)
                }

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(buttonTitle, action: action)
                    .disabled(isGranted)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isGranted ? Color.green.opacity(0.35) : Color.orange.opacity(0.45), lineWidth: 1)
        }
    }
}
