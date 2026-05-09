import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import HotkeyEngine
import os

extension AppCoordinator {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let permissionLog = Logger(subsystem: "WhisperKey", category: "Permissions")

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
        Task { await requestAccessibilityPermissionAndOpenSettings() }
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
        let log = Self.permissionLog
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

    private func requestAccessibilityPermissionAndOpenSettings() async {
        let previousPolicy = NSApp.activationPolicy()
        Self.permissionLog.info("temporarily switching activation policy from \(previousPolicy.rawValue, privacy: .public) to regular for Accessibility prompt")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        requestAccessibilityRegistration()
        provokeAccessibilityRegistrationViaEventTap()

        try? await Task.sleep(nanoseconds: 250_000_000)
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)

        try? await Task.sleep(nanoseconds: 750_000_000)
        NSApp.setActivationPolicy(previousPolicy)
        refreshPermissions(forceOnboarding: true)
    }

    private func requestAccessibilityRegistration() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Self.permissionLog.info("AXIsProcessTrustedWithOptions returned \(trusted, privacy: .public)")
    }

    private func provokeAccessibilityRegistrationViaEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            Self.permissionLog.info("probe CGEventTap was not created before Accessibility trust")
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        Self.permissionLog.info("probe CGEventTap was created")
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
