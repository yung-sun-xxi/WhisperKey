import Foundation

/// Whether the text may still be pasted, given which application was in front when the
/// panel appeared and which is in front now.
///
/// The panel is open for as long as the user holds the key, and an application can come
/// forward in that time — a notification, a launch finishing, an ⌘-tab from the other
/// hand. Pasting then would put text into a window the user was not looking at when the
/// gesture began.
///
/// Process identifiers rather than bundle identifiers: two windows of the same
/// application are the same target, and a relaunched application with the same bundle
/// identifier is not the process the user was typing into.
public enum QuickPasteTargetGuard {
    /// Pastes only when the target is known and unchanged. An unknown frontmost
    /// application at either end is a refusal, not a shrug: there is nothing to compare,
    /// and a wrong paste is worse than a missing one.
    public static func shouldPaste(captured: Int32?, current: Int32?) -> Bool {
        guard let captured, let current else { return false }
        return captured == current
    }
}
