import Foundation

/// How old a clipboard entry is, as the short label its row shows: `now`, `2m`, `1h`,
/// `3d` (#211).
///
/// A pure function of two dates, so the row's label is provable and the snapshot hook can
/// draw the same picture on every run. The controller calls it once per entry when the
/// panel is revealed; nothing ticks while the panel is open, because a hold lasts seconds.
public enum QuickPasteAge {
    private static let minute = 60
    private static let hour = 60 * minute
    private static let day = 24 * hour
    /// Far beyond any real entry, and comfortably inside `Int`.
    private static let longestDistance: TimeInterval = 1e15

    /// Under a minute is `now`, and so is an entry dated after `now` (a clock that moved
    /// back, or the other build's file written a moment ahead). Past that the largest unit
    /// that fits, in whole units rounded down: 119 s is `1m`, 23 h 59 min is `23h`. Days
    /// are the largest unit; an old entry is `400d`, never weeks or months.
    public static func label(capturedAt: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(capturedAt)
        // Also the answer for a distance that is not a number at all.
        guard interval >= Double(minute) else { return "now" }
        // Capped before the conversion, which traps on a value no `Int` can hold: the
        // date comes from a file the other build also writes.
        let seconds = Int(min(interval, longestDistance))
        if seconds < hour { return "\(seconds / minute)m" }
        if seconds < day { return "\(seconds / hour)h" }
        return "\(seconds / day)d"
    }
}
