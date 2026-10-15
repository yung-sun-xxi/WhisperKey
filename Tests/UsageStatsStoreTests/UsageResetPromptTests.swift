import XCTest
@testable import UsageStatsStore

/// The words of the question asked before "Reset selected…" clears counters (#183).
final class UsageResetPromptTests: XCTestCase {
    func testTheTitleNamesSeveralModels() {
        XCTAssertEqual(UsageResetPrompt(modelCount: 2).title, "Reset usage for 2 models?")
        XCTAssertEqual(UsageResetPrompt(modelCount: 11).title, "Reset usage for 11 models?")
    }

    func testTheTitleNamesOneModelInTheSingular() {
        XCTAssertEqual(UsageResetPrompt(modelCount: 1).title, "Reset usage for 1 model?")
    }

    func testTheBodyAndButtonsAreTheTicketsWords() {
        let prompt = UsageResetPrompt(modelCount: 3)
        XCTAssertEqual(
            prompt.informativeText,
            "Their word, audio and cost totals go back to zero. Transcription history is not affected. This can't be undone."
        )
        XCTAssertEqual(UsageResetPrompt.confirmButtonTitle, "Reset")
        XCTAssertEqual(UsageResetPrompt.cancelButtonTitle, "Cancel")
    }
}
