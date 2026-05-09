import ApplicationServices
import AVFoundation

struct PermissionState: Equatable {
    var microphoneStatus: AVAuthorizationStatus
    var accessibilityGranted: Bool

    static func current() -> PermissionState {
        PermissionState(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
