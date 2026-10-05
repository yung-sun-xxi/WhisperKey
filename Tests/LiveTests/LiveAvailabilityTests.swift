import HotkeyEngine
import XCTest
@testable import Live

final class LiveAvailabilityTests: XCTestCase {

    func testTable() {
        let rows: [(enabled: Bool, key: Bool, trigger: TriggerKey, expected: LiveAvailability)] = [
            (true, true, .rightOption, .available),
            (true, true, .rightCommand, .available),
            (false, true, .rightOption, .off),
            (false, true, .rightCommand, .off),
            (true, false, .rightOption, .needsOpenAIKey),
            (false, false, .rightOption, .needsOpenAIKey),
            (true, true, .rightShift, .unavailableWithTrigger),
            (false, true, .rightShift, .unavailableWithTrigger),
            // A missing key is the first thing to fix, whatever the trigger.
            (true, false, .rightShift, .needsOpenAIKey),
        ]
        for row in rows {
            XCTAssertEqual(
                LiveAvailability.evaluate(liveEnabled: row.enabled, hasOpenAIKey: row.key, trigger: row.trigger),
                row.expected,
                "enabled=\(row.enabled) key=\(row.key) trigger=\(row.trigger)"
            )
        }
    }

    func testOnlyAvailableIsAvailable() {
        XCTAssertTrue(LiveAvailability.available.isAvailable)
        XCTAssertFalse(LiveAvailability.off.isAvailable)
        XCTAssertFalse(LiveAvailability.needsOpenAIKey.isAvailable)
        XCTAssertFalse(LiveAvailability.unavailableWithTrigger.isAvailable)
    }

    func testMessages() {
        XCTAssertNil(LiveAvailability.available.message)
        XCTAssertNil(LiveAvailability.off.message)
        XCTAssertEqual(LiveAvailability.needsOpenAIKey.message, "Live needs an OpenAI key")
        XCTAssertEqual(LiveAvailability.unavailableWithTrigger.message, "Live is unavailable with the Right Shift trigger")
    }
}

final class LiveBasePromptTests: XCTestCase {

    func testBasePromptCoversTheSpokenManner() {
        let text = LiveBasePrompt.text.lowercased()
        XCTAssertFalse(text.isEmpty)
        for phrase in ["spoken", "one or two sentences", "answer first", "list", "link", "markdown", "language"] {
            XCTAssertTrue(text.contains(phrase), "base prompt should mention \(phrase)")
        }
    }
}
