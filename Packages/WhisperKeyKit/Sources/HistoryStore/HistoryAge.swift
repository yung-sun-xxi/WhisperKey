import Foundation

/// How old a history entry is, as the short coarse label its popover row shows: `now`,
/// `5m`, `3h`, `1d`, `2w`, `4mo`, `1y` (#220).
///
/// A pure function of two dates, so the row's label is provable; the row passes the
/// current minute in and redraws on a minute tick while the popover is open.
///
/// The boundaries, each label in whole units rounded down:
/// - under 60 s, or dated after `now` (a clock that moved back): `now`
/// - under 60 min: minutes, `1m` … `59m`
/// - under 24 h: hours, `1h` … `23h`
/// - under 7 days: days, `1d` … `6d`
/// - under 30 days: weeks, `1w` … `4w`
/// - under 365 days: months of 30 days, `1mo` … `12mo`
/// - from 365 days: years of 365 days, `1y` and up
///
/// The quick paste popup's `QuickPasteAge` (#211) counts days without limit instead; the
/// two lists show different spans and were decided separately.
public enum HistoryAge {
    private static let minute = 60
    private static let hour = 60 * minute
    private static let day = 24 * hour
    private static let week = 7 * day
    private static let month = 30 * day
    private static let year = 365 * day
    /// Far beyond any real entry, and comfortably inside `Int`.
    private static let longestDistance: TimeInterval = 1e15

    public static func label(createdAt: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(createdAt)
        // Also the answer for a distance that is not a number at all.
        guard interval >= Double(minute) else { return "now" }
        // Capped before the conversion, which traps on a value no `Int` can hold: the
        // date comes from a file the other build also writes.
        let seconds = Int(min(interval, longestDistance))
        if seconds < hour { return "\(seconds / minute)m" }
        if seconds < day { return "\(seconds / hour)h" }
        if seconds < week { return "\(seconds / day)d" }
        if seconds < month { return "\(seconds / week)w" }
        if seconds < year { return "\(seconds / month)mo" }
        return "\(seconds / year)y"
    }
}
