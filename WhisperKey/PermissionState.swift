import ApplicationServices
import AVFoundation

nonisolated struct PermissionState: Equatable {
    var microphoneStatus: AVAuthorizationStatus
    var accessibilityGranted: Bool

    static func current() -> PermissionState {
        PermissionState(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    static func currentDetached() async -> PermissionState {
        await Task.detached(priority: .utility) { PermissionState.current() }.value
    }

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
