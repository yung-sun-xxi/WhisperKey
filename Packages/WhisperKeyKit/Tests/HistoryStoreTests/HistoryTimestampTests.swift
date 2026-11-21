import Foundation
import XCTest
@testable import HistoryStore

/// The full history window's timestamp (#164, the owner's decision of 2026-10-14):
/// "18 Sep 12:37" — the day without a leading zero, the English month abbreviated,
/// 24-hour time, no year and no language. The same whatever the Mac's own language and
/// region, in the Mac's time zone.
final class HistoryTimestampTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTheMockupsTimestamp() {
        XCTAssertEqual(HistoryTimestamp.string(from: date(2026, 9, 18, 12, 37, in: utc), timeZone: utc), "18 Sep 12:37")
    }

    func testASingleDigitDayHasNoLeadingZero() {
        XCTAssertEqual(HistoryTimestamp.string(from: date(2026, 3, 5, 9, 4, in: utc), timeZone: utc), "5 Mar 09:04")
    }

    func testMidnightIsZeroHundredHours() {
        XCTAssertEqual(HistoryTimestamp.string(from: date(2026, 1, 1, 0, 5, in: utc), timeZone: utc), "1 Jan 00:05")
    }

    func testTheEveningIsTwentyFourHourTime() {
        XCTAssertEqual(HistoryTimestamp.string(from: date(2026, 12, 31, 23, 59, in: utc), timeZone: utc), "31 Dec 23:59")
    }

    /// Every month's abbreviation is the English three letters: "Sep", never "Sept".
    func testEveryMonthIsTheEnglishAbbreviation() {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        for (index, name) in months.enumerated() {
            XCTAssertEqual(
                HistoryTimestamp.string(from: date(2025, index + 1, 14, 8, 30, in: utc), timeZone: utc),
                "14 \(name) 08:30"
            )
        }
    }

    /// The year is never shown, an earlier year included.
    func testNoYear() {
        let text = HistoryTimestamp.string(from: date(2019, 7, 2, 18, 5, in: utc), timeZone: utc)
        XCTAssertEqual(text, "2 Jul 18:05")
        XCTAssertFalse(text.contains("2019"))
    }

    /// The clock is the given zone's: the same instant reads two hours later in Madrid's
    /// summer time, a day later past midnight.
    func testTheTimeIsTheZones() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let instant = date(2026, 9, 18, 23, 15, in: utc)
        XCTAssertEqual(HistoryTimestamp.string(from: instant, timeZone: utc), "18 Sep 23:15")
        XCTAssertEqual(HistoryTimestamp.string(from: instant, timeZone: madrid), "19 Sep 01:15")
    }

    /// Without a zone it reads the Mac's current one.
    func testTheDefaultZoneIsTheCurrentOne() {
        let instant = date(2026, 9, 18, 12, 37, in: utc)
        XCTAssertEqual(HistoryTimestamp.string(from: instant), HistoryTimestamp.string(from: instant, timeZone: .current))
    }
}
