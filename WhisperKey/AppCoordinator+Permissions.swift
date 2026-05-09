import AppKit
import AVFoundation
import HotkeyEngine
import os

extension AppCoordinator {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    func refreshPermissions(forceOnboarding: Bool = false) {
        let snapshot = PermissionState.current()
        permissions = snapshot

        synchronizeHotkey(with: snapshot)
        synchronizePermissionDrivenState(with: snapshot)
        onboardingWindowController?.sync(with: snapshot, forceShow: forceOnboarding)
    }

    func requestMicrophonePermission() {
        Task { await requestMicrophonePermissionAsync() }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(Self.microphoneSettingsURL)
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        refreshPermissions()
    }

    func observeWorkspaceActivation() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions(forceOnboarding: true)
            }
        }
    }

    func startPermissionPolling() {
        permissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.refreshPermissions()
            }
        }
    }

    private func requestMicrophonePermissionAsync() async {
        let log = Logger(subsystem: "WhisperKey", category: "Permissions")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("microphone authorizationStatus before onboarding request: \(status.rawValue, privacy: .public)")

        switch status {
        case .authorized:
            refreshPermissions()
            return
        case .notDetermined:
            await requestMicrophoneWithRegularPolicy(log: log)
        case .denied, .restricted:
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }

        refreshPermissions(forceOnboarding: true)
    }

    private func requestMicrophoneWithRegularPolicy(log: Logger) async {
        let previousPolicy = NSApp.activationPolicy()
        log.info("temporarily switching activation policy from \(previousPolicy.rawValue, privacy: .public) to regular for mic prompt")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        log.info("microphone requestAccess returned: \(granted, privacy: .public)")

        NSApp.setActivationPolicy(previousPolicy)
    }

    private func synchronizeHotkey(with snapshot: PermissionState) {
        guard snapshot.accessibilityGranted else {
            hotkey.stop()
            hotkeyStarted = false
            return
        }

        guard !hotkeyStarted else { return }
        hotkeyStarted = hotkey.start()
        if !hotkeyStarted {
            Logger(subsystem: "WhisperKey", category: "Permissions")
                .error("CGEventTap could not be created even though Accessibility is trusted")
        }
    }

    private func synchronizePermissionDrivenState(with snapshot: PermissionState) {
        guard state != .recording, state != .transcribing else { return }

        if !snapshot.accessibilityGranted || !hotkeyStarted {
            updateState(.accessibilityDenied)
        } else if !snapshot.microphoneGranted {
            updateState(.microphoneDenied)
        } else if state == .accessibilityDenied || state == .microphoneDenied {
            updateState(.idle)
            hotkey.setAppState(.idle)
        }
    }
}
