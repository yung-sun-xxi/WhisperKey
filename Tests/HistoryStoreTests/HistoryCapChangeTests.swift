import XCTest
@testable import HistoryStore

/// Lowering History size is the one setting change that deletes entries, from a file the
/// release and dev apps share (#146). Settings asks first; these tests pin when it asks,
/// how many entries it says will go, and the words it uses.
final class HistoryCapChangeTests: XCTestCase {

    // MARK: - When to ask

    func testRaisingNeverAsksEvenWhenTheFileIsLargerThanTheNewLimit() {
        // This app's cap is 10, the other app keeps 50 in the file; raising to 20 trims nothing.
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 10, proposedLimit: 20, fileEntryCount: 50),
            .apply(limit: 20)
        )
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 0, proposedLimit: 1, fileEntryCount: 30),
            .apply(limit: 1)
        )
    }

    func testUnchangedLimitDoesNotAsk() {
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 30, proposedLimit: 30, fileEntryCount: 50),
            .apply(limit: 30)
        )
    }

    func testLoweringToExactlyTheFileSizeDoesNotAsk() {
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 30, proposedLimit: 12, fileEntryCount: 12),
            .apply(limit: 12)
        )
    }

    func testLoweringAboveTheFileSizeDoesNotAsk() {
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 30, proposedLimit: 20, fileEntryCount: 7),
            .apply(limit: 20)
        )
    }

    func testLoweringOneBelowTheFileSizeAsksToDeleteOne() {
        guard case .confirm(let prompt) = HistoryCapChange.evaluate(
            currentLimit: 30, proposedLimit: 29, fileEntryCount: 30
        ) else { return XCTFail("lowering 30 to 29 with 30 entries must ask") }
        XCTAssertEqual(prompt.deletedCount, 1)
        XCTAssertEqual(prompt.newLimit, 29)
    }

    func testDeletedCountCountsTheWholeFileNotThisAppsCap() {
        // This app shows 30, the other app keeps 50 in the file. Lowering to 25 trims the
        // file to 25, so 25 entries go, not 5.
        guard case .confirm(let prompt) = HistoryCapChange.evaluate(
            currentLimit: 30, proposedLimit: 25, fileEntryCount: 50
        ) else { return XCTFail("must ask") }
        XCTAssertEqual(prompt.deletedCount, 25)
        XCTAssertEqual(prompt.fileEntryCount, 50)
    }

    func testProposedLimitIsClampedLikeSetMaxEntries() {
        XCTAssertEqual(
            HistoryCapChange.evaluate(currentLimit: 1000, proposedLimit: 5000, fileEntryCount: 40),
            .apply(limit: 1000)
        )
        guard case .confirm(let prompt) = HistoryCapChange.evaluate(
            currentLimit: 30, proposedLimit: -4, fileEntryCount: 3
        ) else { return XCTFail("a negative limit is 0 and deletes everything") }
        XCTAssertEqual(prompt.newLimit, 0)
        XCTAssertEqual(prompt.deletedCount, 3)
    }

    // MARK: - Wording

    func testWordingForSeveralEntries() {
        let prompt = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 25, otherAppName: nil)
        XCTAssertEqual(prompt.title, "Delete 5 oldest entries?")
        XCTAssertEqual(
            prompt.informativeText,
            "Their audio is deleted too. This can't be undone."
        )
        XCTAssertEqual(prompt.confirmButtonTitle, "Delete 5 Entries")
        XCTAssertEqual(HistoryCapChangePrompt.cancelButtonTitle, "Cancel")
    }

    func testWordingForOneEntry() {
        let prompt = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 29, otherAppName: nil)
        XCTAssertEqual(prompt.title, "Delete the oldest entry?")
        XCTAssertEqual(
            prompt.informativeText,
            "Its audio is deleted too. This can't be undone."
        )
        XCTAssertEqual(prompt.confirmButtonTitle, "Delete 1 Entry")
    }

    func testWordingForALimitOfOne() {
        let prompt = HistoryCapChangePrompt(fileEntryCount: 4, newLimit: 1, otherAppName: nil)
        XCTAssertEqual(prompt.title, "Delete 3 oldest entries?")
        XCTAssertEqual(prompt.informativeText, "Their audio is deleted too. This can't be undone.")
    }

    func testWordingForALimitOfZero() {
        let all = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 0, otherAppName: nil)
        XCTAssertEqual(all.title, "Delete all 30 entries?")
        XCTAssertEqual(
            all.informativeText,
            "Their audio is deleted too. This can't be undone."
        )
        XCTAssertEqual(all.confirmButtonTitle, "Delete 30 Entries")

        let only = HistoryCapChangePrompt(fileEntryCount: 1, newLimit: 0, otherAppName: nil)
        XCTAssertEqual(only.title, "Delete the only entry?")
        XCTAssertEqual(
            only.informativeText,
            "Its audio is deleted too. This can't be undone."
        )
        XCTAssertEqual(only.confirmButtonTitle, "Delete 1 Entry")
    }

    func testSharedHistorySentenceAppearsOnlyWhenTheOtherAppIsInstalled() {
        let shared = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 25, otherAppName: "WhisperKey Dev")
        XCTAssertEqual(
            shared.informativeText,
            "Their audio is deleted too. This can't be undone. WhisperKey Dev loses them too."
        )
        let sharedOne = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 29, otherAppName: "WhisperKey")
        XCTAssertTrue(
            sharedOne.informativeText.hasSuffix(" WhisperKey loses it too."),
            sharedOne.informativeText
        )

        let alone = HistoryCapChangePrompt(fileEntryCount: 30, newLimit: 25, otherAppName: nil)
        XCTAssertFalse(alone.informativeText.contains("loses"), alone.informativeText)
    }

    func testEvaluateCarriesTheOtherAppIntoThePrompt() {
        guard case .confirm(let prompt) = HistoryCapChange.evaluate(
            currentLimit: 30, proposedLimit: 25, fileEntryCount: 30, otherAppName: "WhisperKey Dev"
        ) else { return XCTFail("must ask") }
        XCTAssertEqual(prompt.otherAppName, "WhisperKey Dev")
    }

    // MARK: - Which app shares the file

    func testCounterpartOfTheReleaseAppIsTheDevAppAndBack() {
        XCTAssertEqual(
            HistorySharingApp.counterpart(ofBundleIdentifier: "yung-sun-xxi.WhisperKey"),
            HistorySharingApp(bundleIdentifier: "yung-sun-xxi.WhisperKey.dev", name: "WhisperKey Dev")
        )
        XCTAssertEqual(
            HistorySharingApp.counterpart(ofBundleIdentifier: "yung-sun-xxi.WhisperKey.dev"),
            HistorySharingApp(bundleIdentifier: "yung-sun-xxi.WhisperKey", name: "WhisperKey")
        )
        XCTAssertNil(HistorySharingApp.counterpart(ofBundleIdentifier: nil))
        XCTAssertNil(HistorySharingApp.counterpart(ofBundleIdentifier: "com.apple.xctest"))
    }

    // MARK: - The count comes from the file

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhisperKey-HistoryCapChangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testFileEntryCountIncludesEntriesBeyondThisAppsCap() {
        let url = tempDir.appendingPathComponent("history.json")
        let otherApp = HistoryStore(url: url, maxEntries: 10)
        for i in 1...6 {
            otherApp.append(text: "e\(i)", providerID: "openai", language: nil,
                            now: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let thisApp = HistoryStore(url: url, maxEntries: 2)
        XCTAssertEqual(thisApp.entries.count, 2)
        XCTAssertEqual(thisApp.fileEntryCount, 6)

        // The other app writes again; the count is read fresh, not left at the last load.
        otherApp.append(text: "e7", providerID: "openai", language: nil,
                        now: Date(timeIntervalSince1970: 7))
        XCTAssertEqual(thisApp.fileEntryCount, 7)
        XCTAssertEqual(thisApp.entries.map(\.text), ["e7", "e6"])
    }
}
