import AppKit
import AVFoundation
import os

extension AppCoordinator {
    func bootstrapMicrophonePermission() async {
        let log = Logger(subsystem: "WhisperKey", category: "Permissions")
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("microphone authorizationStatus at bootstrap: \(status.rawValue, privacy: .public)")

        switch status {
        case .authorized:
            return
        case .notDetermined:
            await requestMicrophoneWithRegularPolicy(log: log)
        case .denied, .restricted:
            await MainActor.run {
                if state == .idle { updateState(.microphoneDenied) }
            }
        @unknown default:
            break
        }
    }

    private func requestMicrophoneWithRegularPolicy(log: Logger) async {
        let previousPolicy = await MainActor.run { NSApp.activationPolicy() }
        log.info("temporarily switching activation policy from \(previousPolicy.rawValue, privacy: .public) to regular for mic prompt")

        await MainActor.run {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        log.info("microphone requestAccess returned: \(granted, privacy: .public)")

        await MainActor.run {
            NSApp.setActivationPolicy(previousPolicy)
            if granted {
                if state == .microphoneDenied { updateState(.idle) }
            } else {
                updateState(.microphoneDenied)
            }
        }
    }
}
