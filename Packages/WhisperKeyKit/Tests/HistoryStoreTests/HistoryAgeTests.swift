import Foundation
import XCTest
@testable import HistoryStore

/// The age on a popover history row (#220): `now`, then the largest unit that fits —
/// minutes, hours, days, weeks, months, years — in whole units rounded down. The table
/// spells the labels out rather than computing them, so a moved boundary fails here
/// instead of moving along with the implementation.
final class HistoryAgeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let minute: TimeInterval = 60
    private var hour: TimeInterval { 60 * minute }
    private var day: TimeInterval { 24 * hour }

    private func label(secondsAgo: TimeInterval) -> String {
        HistoryAge.label(createdAt: now.addingTimeInterval(-secondsAgo), now: now)
    }

    private func assertTable(_ table: [(secondsAgo: TimeInterval, label: String, what: String)], file: StaticString = #filePath, line: UInt = #line) {
        for row in table {
            XCTAssertEqual(label(secondsAgo: row.secondsAgo), row.label, row.what, file: file, line: line)
        }
    }

    func testNowUnderAMinute() {
        assertTable([
            (0, "now", "this instant"),
            (1, "now", "a second"),
            (59.999, "now", "a hair under a minute"),
        ])
    }

    func testMinutes() {
        assertTable([
            (60, "1m", "60 s"),
            (119, "1m", "a second under two minutes"),
            (5 * minute, "5m", "five minutes"),
            (60 * minute - 1, "59m", "a second under an hour"),
        ])
    }

    func testHours() {
        assertTable([
            (hour, "1h", "60 min"),
            (3 * hour, "3h", "three hours"),
            (day - 1, "23h", "a second under a day"),
        ])
    }

    func testDays() {
        assertTable([
            (day, "1d", "24 h"),
            (2 * day - 1, "1d", "a second under two days"),
            (7 * day - 1, "6d", "a second under a week"),
        ])
    }

    func testWeeks() {
        assertTable([
            (7 * day, "1w", "seven days"),
            (14 * day - 1, "1w", "a second under two weeks"),
            (14 * day, "2w", "two weeks"),
            (30 * day - 1, "4w", "a second under 30 days"),
        ])
    }

    func testMonthsAreThirtyDays() {
        assertTable([
            (30 * day, "1mo", "30 days"),
            (60 * day - 1, "1mo", "a second under 60 days"),
            (120 * day, "4mo", "120 days"),
            (365 * day - 1, "12mo", "a second under 365 days"),
        ])
    }

    func testYearsAre365Days() {
        assertTable([
            (365 * day, "1y", "365 days"),
            (730 * day - 1, "1y", "a second under 730 days"),
            (730 * day, "2y", "730 days"),
        ])
    }

    /// A clock that moved back, or a file another build wrote a moment ahead, dates an
    /// entry after `now`: it is `now`, not a negative age.
    func testAnEntryFromTheFutureIsNow() {
        assertTable([
            (-1, "now", "a second ahead"),
            (-10 * day, "now", "ten days ahead"),
        ])
    }

    /// The date comes from a file; a distance no `Int` can hold must not trap.
    func testADistanceBeyondAnyRealEntryDoesNotTrap() {
        XCTAssertEqual(HistoryAge.label(createdAt: .distantPast, now: .distantFuture).last, "y")
        XCTAssertEqual(label(secondsAgo: .infinity).last, "y")
        XCTAssertEqual(label(secondsAgo: .nan), "now")
    }
}
