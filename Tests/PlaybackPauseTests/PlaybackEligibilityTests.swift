import XCTest
@testable import PlaybackPause

/// Rule 2 of #196: which processes running output may be paused with the media key.
final class PlaybackEligibilityTests: XCTestCase {
    private let ownPID: pid_t = 4242

    private func eligible(_ bundleID: String?, pid: pid_t = 900) -> Bool {
        PlaybackEligibility.isEligible(bundleID: bundleID, pid: pid, ownPID: ownPID)
    }

    func testOrdinaryPlayersAndBrowserHelpersAreEligible() {
        for bundleID in [
            "com.google.Chrome.helper",
            "com.brave.Browser.helper",
            "org.videolan.vlc",
            "com.spotify.client",
        ] {
            XCTAssertTrue(eligible(bundleID), bundleID)
        }
    }

    func testOwnProcessIsIgnored() {
        XCTAssertFalse(eligible("com.google.Chrome.helper", pid: ownPID))
        XCTAssertFalse(eligible("yung-sun-xxi.WhisperKey.dev", pid: ownPID))
        XCTAssertTrue(eligible("com.google.Chrome.helper", pid: ownPID + 1))
    }

    func testEntriesWithoutBundleIDAreIgnored() {
        XCTAssertFalse(eligible(nil))
        XCTAssertFalse(eligible(""))
    }

    func testAppleSystemProcessesAreIgnored() {
        for bundleID in [
            "com.apple.CoreSpeech",
            "com.apple.PowerChime",
            "com.apple.universalaccessd",
            "com.apple.systemsoundserverd",
            "com.apple.WebKit.Networking",
        ] {
            XCTAssertFalse(eligible(bundleID), bundleID)
        }
    }

    func testAppleMediaAppsOnTheAllowListAreEligible() {
        for bundleID in [
            "com.apple.WebKit.GPU",
            "com.apple.Safari",
            "com.apple.podcasts",
            "com.apple.TV",
            "com.apple.QuickTimePlayerX",
        ] {
            XCTAssertTrue(eligible(bundleID), bundleID)
        }
    }

    func testCallAppsAreIgnoredIncludingTheirHelpers() {
        for bundleID in [
            "us.zoom.xos",
            "us.zoom.xos.helper",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.microsoft.teams2.helper",
            "com.tinyspeck.slackmacgap",
            "com.tinyspeck.slackmacgap.helper",
            "com.hnc.Discord",
            "com.hnc.Discord.helper",
            "ru.keepcoder.Telegram",
            "com.teamspeak.TeamSpeak3",
            "com.apple.avconferenced",
        ] {
            XCTAssertFalse(eligible(bundleID), bundleID)
        }
    }

    func testAppleMusicIsNeverEligibleForTheKey() {
        XCTAssertFalse(eligible("com.apple.Music"))
    }
}
