import PasteEngine

/// What the quick-paste gesture asks the paste path to do about secure text fields.
///
/// A named constant in the package rather than a literal in `QuickPasteController`,
/// because the application target has no test bundle. The controller still has to hand
/// this to the router and that one line is only checked by eye — but the value it hands
/// over is checked by a test.
///
/// The gesture is deliberate — held a key, looked at a list, pointed, released — and
/// pasting a password is one of the things a clipboard popup is for. That is the whole
/// difference from the transcription auto-paste, which fires by itself and keeps
/// `SecureFieldPolicy.refuse`.
public enum QuickPastePolicy {
    public static let secureFieldPolicy: SecureFieldPolicy = .allow
}
