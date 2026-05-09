import Foundation
import AppKit
import ApplicationServices
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

    public init(
        inspector: AXFocusInspector = SystemAXFocusInspector(),
        keyboard: KeyboardSimulator = CGEventKeyboardSimulator()
    ) {
        self.inspector = inspector
        self.keyboard = keyboard
    }

    /// Pure decision function — exposed for testing.
    public static func decide(for focus: AXFocusInfo?) -> PasteDecision {
        guard let focus else { return .clipboardOnly }
        if focus.subrole == secureSubrole { return .clipboardOnly }
        guard let role = focus.role, pasteableRoles.contains(role) else {
            return .clipboardOnly
        }
        return .paste
    }

    /// Inspects the focused element and pastes if the role matrix permits it.
    @discardableResult
    public func attemptPaste() -> PasteDecision {
        let focus = inspector.currentFocus()
        let decision = Self.decide(for: focus)
        pasteLog.info("focus role=\(focus?.role ?? "nil", privacy: .public) subrole=\(focus?.subrole ?? "nil", privacy: .public) decision=\(String(describing: decision), privacy: .public)")
        if decision == .paste {
            keyboard.sendCommandV()
        }
        return decision
    }
}

// MARK: - System inspector

public struct SystemAXFocusInspector: AXFocusInspector {
    public init() {}

    public func currentFocus() -> AXFocusInfo? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let value = focused else { return nil }
        let element = value as! AXUIElement
        let role = Self.string(element, kAXRoleAttribute as CFString)
        let subrole = Self.string(element, kAXSubroleAttribute as CFString)
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
