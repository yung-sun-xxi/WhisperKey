import PasteEngine

/// Something the quick-paste gesture has to tell the user, because otherwise the gesture
/// produced nothing at all.
public enum QuickPasteNotice: Equatable, Sendable {
    /// `PasteEngine` declined — the focused element is a secure text field. The
    /// clipboard-output path restores the clipboard afterwards, so there is nothing
    /// pasted *and* nothing left to paste by hand.
    case pasteRefused
    /// The chosen text could not be put on the clipboard at all, so no paste was even
    /// attempted.
    case clipboardWriteFailed

    public var message: String {
        switch self {
        case .pasteRefused:
            return "WhisperKey did not paste into a password field. The entry was not pasted, and your clipboard is unchanged."
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
            // The one case the whole notice exists for. Reported regardless of whether
            // the restore succeeded: either way the entry is not where it was aimed.
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
