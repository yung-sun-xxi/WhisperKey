import AppKit
import AVFoundation

extension AppCoordinator {
    func bootstrapMicrophonePermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                if granted {
                    if state == .microphoneDenied { updateState(.idle) }
                } else {
                    updateState(.microphoneDenied)
                }
            }
        case .denied, .restricted:
            await MainActor.run {
                if state == .idle { updateState(.microphoneDenied) }
            }
        @unknown default:
            break
        }
    }
}
