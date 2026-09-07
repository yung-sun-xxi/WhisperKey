import PasteEngine
import QuickPaste
import XCTest

/// When the quick-paste gesture has to say something, and when it must stay quiet.
///
/// The whole point of the feature is that a deliberate gesture never produces nothing.
/// The one path where it can is `PasteEngine` declining: the clipboard-output path still
/// restores the clipboard afterwards, so a refused paste leaves nothing pasted *and*
/// nothing to paste by hand. Which results deserve a word is a decision over three
/// booleans, so it lives here rather than as an `if` inside the controller, where the
/// application target has no test bundle to catch it.
final class QuickPasteFeedbackTests: XCTestCase {
    private func result(
        wroteClipboard: Bool,
        pasteDecision: PasteDecision?,
        restoredClipboard: Bool = true
    ) -> TranscriptionOutputResult {
        TranscriptionOutputResult(
            wroteClipboard: wroteClipboard,
            pasteDecision: pasteDecision,
            restoredClipboard: restoredClipboard
        )
    }

    func testASuccessfulPasteSaysNothing() {
        XCTAssertNil(
            QuickPasteFeedback.notice(for: result(wroteClipboard: true, pasteDecision: .paste))
        )
    }

    func testARefusedPasteIsReported() {
        XCTAssertEqual(
            QuickPasteFeedback.notice(for: result(wroteClipboard: true, pasteDecision: .clipboardOnly)),
            .pasteRefused
        )
    }

    /// The refusal is worth reporting whether or not the restore succeeded: either way
    /// the chosen text is not in the field the user was looking at.
    func testARefusedPasteIsReportedEvenWhenTheClipboardWasNotRestored() {
        XCTAssertEqual(
            QuickPasteFeedback.notice(
                for: result(wroteClipboard: true, pasteDecision: .clipboardOnly, restoredClipboard: false)
            ),
            .pasteRefused
        )
    }

    func testAFailedClipboardWriteIsReported() {
        XCTAssertEqual(
            QuickPasteFeedback.notice(for: result(wroteClipboard: false, pasteDecision: nil)),
            .clipboardWriteFailed
        )
    }

    /// Written, but no decision: the work was cancelled between the write and the paste.
    /// Nobody is waiting on the outcome of an abandoned gesture, so this stays quiet.
    func testACancelledAttemptSaysNothing() {
        XCTAssertNil(
            QuickPasteFeedback.notice(for: result(wroteClipboard: true, pasteDecision: nil))
        )
    }

    func testEveryNoticeCarriesAMessage() {
        for notice in [QuickPasteNotice.pasteRefused, .clipboardWriteFailed] {
            XCTAssertFalse(notice.message.isEmpty, "\(notice) has no message")
        }
    }

    /// The popup now asks the paste path to paste into a labelled secure text field, so a
    /// refusal is no longer a password field being protected — it is the paste path not
    /// being able to identify what is focused while macOS secure input is on. A message
    /// that still named a password field would be telling the user something untrue.
    func testTheRefusalMessageNoLongerBlamesAPasswordField() {
        XCTAssertFalse(
            QuickPasteNotice.pasteRefused.message.lowercased().contains("password"),
            "the popup pastes into password fields now; the refusal has another cause"
        )
    }
}
