import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

private let pasteLog = Logger(subsystem: "WhisperKey", category: "PasteEngine")

/// Snapshot of AX role/subrole for the focused UI element.
public struct AXFocusInfo: Equatable, Sendable {
    public let role: String?
    public let subrole: String?

    public init(role: String?, subrole: String?) {
        self.role = role
        self.subrole = subrole
    }
}

public enum PasteDecision: Equatable, Sendable {
    /// Synthesise ⌘V into the focused field.
    case paste
    /// Leave the text on the clipboard only — paste would be unsafe.
    case clipboardOnly
}

public protocol AXFocusInspector: Sendable {
    func currentFocus() -> AXFocusInfo?
}

public protocol KeyboardSimulator: Sendable {
    func sendCommandV()
}

/// Reports whether any process in the system has currently enabled secure
/// keyboard input — the OS-level signal raised by password fields, the login
/// window, and other secret-text contexts.
public protocol SecureInputProbe: Sendable {
    func isSecureInputActive() -> Bool
}

/// Decides whether to auto-paste a transcript and synthesises the ⌘V if so.
public struct PasteEngine: Sendable {
    public static let pasteableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]
    public static let secureSubrole = "AXSecureTextField"

    private let inspector: AXFocusInspector
    private let keyboard: KeyboardSimulator
    private let secureProbe: SecureInputProbe

    public init(
        inspector: AXFocusInspector = SystemAXFocusInspector(),
        keyboard: KeyboardSimulator = CGEventKeyboardSimulator(),
        secureProbe: SecureInputProbe = SystemSecureInputProbe()
    ) {
        self.inspector = inspector
        self.keyboard = keyboard
        self.secureProbe = secureProbe
    }

    /// Pure decision function — exposed for testing.
    ///
    /// - `focus` carries an AX role/subrole snapshot, or nil when AX could
    ///   not return the focused element.
    /// - `secureInputActive` reports whether the system is broadcasting the
    ///   secure-input signal (e.g. a password field is focused somewhere).
    ///
    /// Logic:
    /// 1. AX subrole `AXSecureTextField` -> never paste.
    /// 2. AX role on the pasteable allow-list -> paste.
    /// 3. AX query failed or returned an unknown role: paste only when the
    ///    OS-level secure-input signal is *not* active. This covers Electron
    ///    and other apps that don't expose AX while still being safe around
    ///    real password contexts.
    public static func decide(for focus: AXFocusInfo?, secureInputActive: Bool) -> PasteDecision {
        if focus?.subrole == secureSubrole { return .clipboardOnly }
        if let role = focus?.role, pasteableRoles.contains(role) {
            return .paste
        }
        return secureInputActive ? .clipboardOnly : .paste
    }

    /// Inspects the focused element and pastes if the role matrix permits it.
    @discardableResult
    public func attemptPaste() -> PasteDecision {
        let focus = inspector.currentFocus()
        let secureInputActive = secureProbe.isSecureInputActive()
        let decision = Self.decide(for: focus, secureInputActive: secureInputActive)
        pasteLog.info("focus role=\(focus?.role ?? "nil", privacy: .public) subrole=\(focus?.subrole ?? "nil", privacy: .public) secureInput=\(secureInputActive, privacy: .public) decision=\(String(describing: decision), privacy: .public)")
        if decision == .paste {
            keyboard.sendCommandV()
        }
        return decision
    }
}

// MARK: - System inspector

public struct SystemAXFocusInspector: AXFocusInspector {
    /// Per-call AX timeout. The default of 6 s is too long when we want to
    /// fall back to a different code path quickly.
    private static let axTimeout: Float = 0.5

    /// Brief retry delay when the first focus query returns nil — focus
    /// updates after window switches arrive a few dozen ms late.
    private static let retryDelayUSec: useconds_t = 80_000

    public init() {}

    public func currentFocus() -> AXFocusInfo? {
        if let info = readFocus() { return info }

        usleep(Self.retryDelayUSec)
        if let info = readFocus() { return info }

        pasteLog.info("AX focus query returned nil after retry; frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
        return nil
    }

    private func readFocus() -> AXFocusInfo? {
        if let info = readSystemWideFocus() { return info }
        return readFrontmostAppFocus()
    }

    private func readSystemWideFocus() -> AXFocusInfo? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)
        return readFocusedElement(of: systemWide)
    }

    private func readFrontmostAppFocus() -> AXFocusInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axTimeout)
        return readFocusedElement(of: appElement)
    }

    private func readFocusedElement(of element: AXUIElement) -> AXFocusInfo? {
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let value = focused else { return nil }
        let focusedElement = value as! AXUIElement
        let role = Self.string(focusedElement, kAXRoleAttribute as CFString)
        let subrole = Self.string(focusedElement, kAXSubroleAttribute as CFString)
        if role == nil && subrole == nil { return nil }
        return AXFocusInfo(role: role, subrole: subrole)
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard status == .success else { return nil }
        return raw as? String
    }
}

// MARK: - System secure-input probe

public struct SystemSecureInputProbe: SecureInputProbe {
    public init() {}

    public func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}

// MARK: - CGEvent keyboard simulator

public struct CGEventKeyboardSimulator: KeyboardSimulator {
    /// ANSI virtual key code for the "V" key.
    private static let vKey: CGKeyCode = 0x09

    public init() {}

    public func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: false)
        else {
            pasteLog.error("failed to create CGEvent for ⌘V")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
