import Foundation
import XCTest
@testable import QuickPaste

/// The age label of a row: `now` under a minute, then whole minutes, hours and days,
/// always rounded down. The table spells the labels out rather than computing them, so a
/// change to a boundary fails here instead of moving along with the implementation.
final class QuickPasteAgeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        QuickPasteAge.label(capturedAt: now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testTheLabelAtEveryBoundary() {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour

        let table: [(secondsAgo: TimeInterval, label: String, what: String)] = [
            (0, "now", "this instant"),
            (1, "now", "a second"),
            (59, "now", "59 s"),
            (59.999, "now", "a hair under a minute"),
            (60, "1m", "60 s"),
            (61, "1m", "61 s"),
            (119, "1m", "a second under two minutes"),
            (120, "2m", "two minutes"),
            (59 * minute, "59m", "59 min"),
            (59 * minute + 59, "59m", "a second under an hour"),
            (60 * minute, "1h", "60 min"),
            (hour + 59 * minute + 59, "1h", "a second under two hours"),
            (2 * hour, "2h", "two hours"),
            (23 * hour, "23h", "23 h"),
            (23 * hour + 59 * minute + 59, "23h", "a second under a day"),
            (24 * hour, "1d", "24 h"),
            (2 * day - 1, "1d", "a second under two days"),
            (3 * day, "3d", "three days"),
            (400 * day, "400d", "days are the largest unit"),
        ]

        for row in table {
            XCTAssertEqual(label(secondsAgo: row.secondsAgo), row.label, row.what)
        }
    }

    func testAnEntryFromTheFutureIsNow() {
        // A clock that moved back, or the other build's file written a moment ahead: never
        // a negative age.
        XCTAssertEqual(label(secondsAgo: -1), "now")
        XCTAssertEqual(label(secondsAgo: -3600), "now")
        XCTAssertEqual(label(secondsAgo: -90 * 24 * 3600), "now")
    }

    func testTheLabelDependsOnlyOnTheTwoDates() {
        // The same distance anywhere on the timeline is the same label.
        for origin in [0, 1_000_000, 800_000_000.5] as [TimeInterval] {
            let now = Date(timeIntervalSinceReferenceDate: origin)
            XCTAssertEqual(
                QuickPasteAge.label(capturedAt: now.addingTimeInterval(-7200), now: now),
                "2h",
                "origin \(origin)"
            )
        }
    }
}
