import Foundation

/// How old a clipboard entry is, as the short label its row shows: `now`, `2m`, `1h`, `3d`.
public enum QuickPasteAge {
    public static func label(capturedAt: Date, now: Date) -> String {
        ""
    }
}
