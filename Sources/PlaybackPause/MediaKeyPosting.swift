import AppKit
import Foundation

/// The system Play/Pause media key. It reaches whichever app macOS holds as Now Playing.
public protocol MediaKeyPosting: Sendable {
    func postPlayPause()
}

/// Posts Play/Pause as a key down and key up at the HID tap. Needs Accessibility
/// (`CGPreflightPostEventAccess()`); without it the events are dropped silently.
public struct SystemMediaKeyPoster: MediaKeyPosting {
    /// `NX_KEYTYPE_PLAY` from IOKit/hidsystem/ev_keymap.h.
    static let playKeyType = 16
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the system-defined event subtype for media keys.
    static let auxControlButtonsSubtype: Int16 = 8

    public init() {}

    public func postPlayPause() {
        post(keyDown: true)
        post(keyDown: false)
    }

    private func post(keyDown: Bool) {
        let keyState = keyDown ? 0xa : 0xb
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState) << 8),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Self.auxControlButtonsSubtype,
            data1: (Self.playKeyType << 16) | (keyState << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
