/// What Settings does with a new History size (#146).
///
/// Lowering the cap is the one change that deletes entries, and it trims the file the
/// release and dev apps share, not just this app's view of it. So Settings asks first
/// whenever the new cap is below the number of entries in the file, and applies every
/// other change at once.
public enum HistoryCapChange: Equatable, Sendable {
    /// Nothing will be deleted: set the cap to `limit`.
    case apply(limit: Int)
    /// The cap would delete entries: ask with this prompt before setting it.
    case confirm(HistoryCapChangePrompt)

    /// - Parameters:
    ///   - currentLimit: the cap in force now.
    ///   - proposedLimit: the cap the user asked for; clamped the way
    ///     `HistoryStore.setMaxEntries` clamps it.
    ///   - fileEntryCount: entries in the shared file (`HistoryStore.fileEntryCount`),
    ///     which can exceed `currentLimit` when the other app keeps a bigger cap.
    ///   - otherAppName: the other WhisperKey app that shares the file, when installed.
    public static func evaluate(
        currentLimit: Int,
        proposedLimit: Int,
        fileEntryCount: Int,
        otherAppName: String? = nil
    ) -> HistoryCapChange {
        let current = HistoryStore.clamp(currentLimit)
        let proposed = HistoryStore.clamp(proposedLimit)
        // Raising only shows more of the file; `setMaxEntries` trims only when lowering.
        guard proposed < current, fileEntryCount > proposed else {
            return .apply(limit: proposed)
        }
        return .confirm(HistoryCapChangePrompt(
            fileEntryCount: fileEntryCount,
            newLimit: proposed,
            otherAppName: otherAppName
        ))
    }
}

/// The words of the "lower History size" question. `deletedCount` is what
/// `setMaxEntries` will actually trim: the whole file down to `newLimit`.
public struct HistoryCapChangePrompt: Equatable, Sendable {
    public static let cancelButtonTitle = "Cancel"

    public let fileEntryCount: Int
    public let newLimit: Int
    public let otherAppName: String?

    public init(fileEntryCount: Int, newLimit: Int, otherAppName: String?) {
        self.fileEntryCount = fileEntryCount
        self.newLimit = newLimit
        self.otherAppName = otherAppName
    }

    public var deletedCount: Int { max(fileEntryCount - newLimit, 0) }

    public var title: String {
        if newLimit == 0 {
            return deletedCount == 1 ? "Delete the only entry?" : "Delete all \(deletedCount) entries?"
        }
        return deletedCount == 1 ? "Delete the oldest entry?" : "Delete \(deletedCount) oldest entries?"
    }

    public var informativeText: String {
        let holds = "History holds \(fileEntryCount) \(fileEntryCount == 1 ? "entry" : "entries")"
        let keeps: String
        switch newLimit {
        case 0: keeps = "a limit of 0 keeps none"
        case 1: keeps = "a limit of 1 keeps the newest entry"
        default: keeps = "a limit of \(newLimit) keeps the newest \(newLimit)"
        }
        let deleted: String
        switch (newLimit == 0, deletedCount == 1) {
        case (true, true): deleted = "The entry and its audio will be deleted."
        case (true, false): deleted = "All \(deletedCount) entries and their audio will be deleted."
        case (false, true): deleted = "The oldest entry and its audio will be deleted."
        case (false, false): deleted = "The \(deletedCount) oldest entries and their audio will be deleted."
        }
        var text = "\(holds); \(keeps). \(deleted) This can't be undone."
        if let otherAppName {
            let disappear = deletedCount == 1 ? "it disappears" : "they disappear"
            text += " \(otherAppName) shares this history, so \(disappear) there too."
        }
        return text
    }

    public var confirmButtonTitle: String {
        deletedCount == 1 ? "Delete 1 Entry" : "Delete \(deletedCount) Entries"
    }
}

/// The two WhisperKey apps that share `history.json`: the release app and the dev app.
public struct HistorySharingApp: Equatable, Sendable {
    public let bundleIdentifier: String
    public let name: String

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    public static let release = HistorySharingApp(bundleIdentifier: "yung-sun-xxi.WhisperKey", name: "WhisperKey")
    public static let dev = HistorySharingApp(bundleIdentifier: "yung-sun-xxi.WhisperKey.dev", name: "WhisperKey Dev")

    /// The other app sharing the history with the app whose bundle id is given, or nil
    /// for anything that is neither (a test runner, say).
    public static func counterpart(ofBundleIdentifier bundleIdentifier: String?) -> HistorySharingApp? {
        switch bundleIdentifier {
        case release.bundleIdentifier: dev
        case dev.bundleIdentifier: release
        default: nil
        }
    }
}
