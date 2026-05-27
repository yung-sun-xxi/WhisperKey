import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import HotkeyEngine
import SettingsStore
import os

extension AppCoordinator {
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let permissionLog = Logger(subsystem: "WhisperKey", category: "Permissions")

    func refreshPermissions(forceOnboarding: Bool = false) {
        let snapshot = PermissionState.current()
        permissions = snapshot

        if snapshot.allGranted {
            setPermissionWindowZOrder(.aboveOrdinaryApps)
        }

        synchronizeHotkey(with: snapshot)
        synchronizePermissionDrivenState(with: snapshot)
        onboardingWindowController?.sync(
            with: snapshot,
            forceShow: forceOnboarding && !shouldSuppressPermissionOnboardingForWelcome,
            zOrderState: permissionWindowZOrderState
        )
    }

    func requestMicrophonePermission() {
        closeTransientWindowsBeforeExternalPermissionUI()
        refreshPermissions(forceOnboarding: true)
        Task { await requestMicrophonePermissionAsync() }
    }

    func openMicrophoneSettings() {
        closeTransientWindowsBeforeExternalPermissionUI()
        refreshPermissions(forceOnboarding: true)
        setPermissionWindowZOrder(.yieldingToSystemSettings)
        openSystemSettings(Self.microphoneSettingsURL)
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        closeTransientWindowsBeforeExternalPermissionUI()
        refreshPermissions(forceOnboarding: true)
        Task { await requestAccessibilityPermissionAndOpenSettings() }
    }

    func observeWorkspaceActivation() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedProcessID = activatedApplication?.processIdentifier
            let activatedBundleIdentifier = activatedApplication?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleWorkspaceActivation(
                    bundleIdentifier: activatedBundleIdentifier,
                    processIdentifier: activatedProcessID
                )
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

    private func handleWorkspaceActivation(bundleIdentifier: String?, processIdentifier: pid_t?) {
        let whisperKeyBecameActive = processIdentifier == ProcessInfo.processInfo.processIdentifier

        if permissionWindowZOrderState == .yieldingToSystemSettings,
           !Self.isSystemSettingsBundleIdentifier(bundleIdentifier) {
            restorePermissionWindowAboveOrdinaryApps()
            return
        }

        refreshPermissions(forceOnboarding: whisperKeyBecameActive)
    }

    private static func isSystemSettingsBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.systempreferences"
            || bundleIdentifier == "com.apple.SystemSettings"
    }

    private func setPermissionWindowZOrder(
        _ state: PermissionWindowZOrderState,
        bringToFront: Bool = false
    ) {
        permissionWindowZOrderState = state
        onboardingWindowController?.applyZOrder(state, bringToFront: bringToFront)
    }

    private func closeTransientWindowsBeforeExternalPermissionUI() {
        closeMenuBarPopoverHandler?()
        SettingsWindowController.hide()
    }

    private func restorePermissionWindowAboveOrdinaryApps() {
        setPermissionWindowZOrder(.aboveOrdinaryApps, bringToFront: true)
        refreshPermissions(forceOnboarding: true)
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

        setPermissionWindowZOrder(.yieldingToMicrophonePrompt)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        log.info("microphone requestAccess returned: \(granted, privacy: .public)")

        NSApp.setActivationPolicy(previousPolicy)
        restorePermissionWindowAboveOrdinaryApps()
    }

    private func requestAccessibilityPermissionAndOpenSettings() async {
        let previousPolicy = NSApp.activationPolicy()
        Self.permissionLog.info("temporarily switching activation policy from \(previousPolicy.rawValue, privacy: .public) to regular for Accessibility prompt")

        setPermissionWindowZOrder(.yieldingToAccessibilityPrompt)
        NSApp.setActivationPolicy(.regular)

        requestAccessibilityRegistration()
        provokeAccessibilityRegistrationViaEventTap()

        try? await Task.sleep(nanoseconds: 250_000_000)
        setPermissionWindowZOrder(.yieldingToSystemSettings)
        openSystemSettings(Self.accessibilitySettingsURL)

        try? await Task.sleep(nanoseconds: 750_000_000)
        NSApp.setActivationPolicy(previousPolicy)
        refreshPermissions(forceOnboarding: true)
    }

    private func openSystemSettings(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSWorkspace.shared.runningApplications
                    .first { Self.isSystemSettingsBundleIdentifier($0.bundleIdentifier) }?
                    .activate(options: [.activateAllWindows])
            }
        }
    }

    private func requestAccessibilityRegistration() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
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
