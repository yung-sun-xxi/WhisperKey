import Foundation

/// Which processes running output may be paused with the media key (#196, rule 2).
public enum PlaybackEligibility {
    /// Apple Music is paused through AppleScript only (rule 1); its output flag stays up
    /// for minutes after a pause, so it never counts for the key.
    static let appleMusicBundleID = "com.apple.Music"

    /// `com.apple.*` processes that do play media. Every other `com.apple.*` process is a
    /// system daemon (alert sounds, speech, chimes) and is ignored. Safari and every
    /// other WebKit app play through `com.apple.WebKit.GPU`.
    static let appleMediaBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.Safari",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
    ]

    /// Call apps, matched by prefix so their helper processes (`<app>.helper`,
    /// `com.microsoft.teams2.helper`) count too. FaceTime plays through `avconferenced`.
    static let callAppBundleIDPrefixes = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "ru.keepcoder.Telegram",
        "com.teamspeak",
        "com.apple.avconferenced",
    ]

    public static func isEligible(bundleID: String?, pid: pid_t, ownPID: pid_t) -> Bool {
        guard pid != ownPID, let bundleID, !bundleID.isEmpty else { return false }
        if bundleID == appleMusicBundleID { return false }
        if callAppBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return false }
        if bundleID.hasPrefix("com.apple."), !appleMediaBundleIDs.contains(bundleID) { return false }
        return true
    }

    static func isEligible(_ process: AudioProcess, ownPID: pid_t) -> Bool {
        isEligible(bundleID: process.bundleID, pid: process.pid, ownPID: ownPID)
    }
}
