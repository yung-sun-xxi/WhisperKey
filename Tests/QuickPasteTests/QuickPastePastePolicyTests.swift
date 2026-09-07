import PasteEngine
import QuickPaste
import XCTest

/// Which secure-field policy the quick-paste gesture asks the paste path for.
///
/// It is a named constant in the package rather than a literal in `QuickPasteController`
/// because the application target has no test bundle. The controller still has to hand it
/// to the router, and that one line is checked by eye — but the *value* is not.
final class QuickPastePastePolicyTests: XCTestCase {
    /// The gesture is deliberate: the user held a key, looked at a list, pointed at an
    /// entry and released. Pasting a password is one of the things the popup is for.
    func testTheQuickPasteGestureAsksToPasteIntoSecureFields() {
        XCTAssertEqual(QuickPastePolicy.secureFieldPolicy, .allow)
    }

    /// The transcription auto-paste fires on its own and must not be reached by this.
    func testTheEngineDefaultIsStillToRefuse() {
        XCTAssertEqual(
            PasteEngine.decide(
                for: AXFocusInfo(role: "AXTextField", subrole: "AXSecureTextField"),
                secureInputActive: false
            ),
            .clipboardOnly
        )
    }
}
