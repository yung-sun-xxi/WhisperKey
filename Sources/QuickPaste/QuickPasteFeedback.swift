import PasteEngine

/// Something the quick-paste gesture has to tell the user, because otherwise the gesture
/// produced nothing at all.
public enum QuickPasteNotice: Equatable, Sendable {
    /// `PasteEngine` declined. The clipboard-output path restores the clipboard
    /// afterwards, so there is nothing pasted *and* nothing left to paste by hand.
    ///
    /// The popup asks for `SecureFieldPolicy.allow`, so a field the application has
    /// labelled `AXSecureTextField` is no longer a reason to be here — a password field
    /// in a native application or Safari is pasted into like any other field. What is
    /// left is the unknown-role branch: the paste path could not identify what is focused
    /// (an Electron application, or AX returning nothing at all) while macOS secure input
    /// was switched on. The message must therefore not blame a password field.
    case pasteRefused
    /// The chosen text could not be put on the clipboard at all, so no paste was even
    /// attempted.
    case clipboardWriteFailed

    public var message: String {
        switch self {
        case .pasteRefused:
            return "WhisperKey could not paste into the focused field while macOS secure input was on. The entry was not pasted, and your clipboard is unchanged."
        case .clipboardWriteFailed:
            return "WhisperKey could not put the entry on the clipboard, so nothing was pasted."
        }
    }
}

/// When the quick-paste gesture speaks up, decided from the result the clipboard-output
/// path returns.
///
/// This is a pure function over `TranscriptionOutputResult` rather than an `if` inside
/// `QuickPasteController` because the application target has no test bundle: an `if`
/// there is checked by eye, and the whole point of the rule is the case that is hard to
/// reproduce by hand — a password field focused at the moment of release.
public enum QuickPasteFeedback {
    public static func notice(for result: TranscriptionOutputResult) -> QuickPasteNotice? {
        switch result.pasteDecision {
        case .paste:
            // Pasted. The text is in the field the user was looking at; saying so would
            // be noise on top of the thing they can already see.
            return nil
        case .clipboardOnly:
            // The one case the whole notice exists for. Now reachable only through the
            // unknown-role branch — the popup asks for `SecureFieldPolicy.allow`, so a
            // labelled secure field is pasted into rather than refused. Reported
            // regardless of whether the restore succeeded: either way the entry is not
            // where it was aimed.
            return .pasteRefused
        case nil:
            // No decision was reached. Either the clipboard write failed before the
            // paste could be attempted — worth reporting, because nothing happened at
            // all — or the work was cancelled between the write and the paste, and
            // nobody is waiting on the outcome of an abandoned gesture.
            return result.wroteClipboard ? nil : .clipboardWriteFailed
        }
    }
}
