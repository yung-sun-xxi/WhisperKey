import Foundation

/// When an entry was made, as the full history window shows it (#164, the owner's
/// decision of 2026-10-14): `18 Sep 12:37` — the day without a leading zero, the English
/// month abbreviated, the 24-hour clock, no year and no language.
///
/// The locale is fixed (`en_US_POSIX`), so the text is the same whatever the Mac's
/// language and region; only the time zone is the Mac's.
public enum HistoryTimestamp {
    /// The pattern, in `DateFormatter` terms.
    public static let format = "d MMM HH:mm"

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }()

    /// `date` in `timeZone`, the Mac's current one by default.
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        lock.lock()
        defer { lock.unlock() }
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
