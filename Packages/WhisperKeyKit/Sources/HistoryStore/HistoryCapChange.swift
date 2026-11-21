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
    public static func evaluate(
        currentLimit: Int,
        proposedLimit: Int,
        fileEntryCount: Int
    ) -> HistoryCapChange {
        let current = HistoryStore.clamp(currentLimit)
        let proposed = HistoryStore.clamp(proposedLimit)
        // Raising only shows more of the file; `setMaxEntries` trims only when lowering.
        guard proposed < current, fileEntryCount > proposed else {
            return .apply(limit: proposed)
        }
        return .confirm(HistoryCapChangePrompt(fileEntryCount: fileEntryCount, newLimit: proposed))
    }
}

/// The words of the "lower History size" question. `deletedCount` is what
/// `setMaxEntries` will actually trim: the whole file down to `newLimit`.
public struct HistoryCapChangePrompt: Equatable, Sendable {
    public static let cancelButtonTitle = "Cancel"

    public let fileEntryCount: Int
    public let newLimit: Int

    public init(fileEntryCount: Int, newLimit: Int) {
        self.fileEntryCount = fileEntryCount
        self.newLimit = newLimit
    }

    public var deletedCount: Int { max(fileEntryCount - newLimit, 0) }

    public var title: String {
        if newLimit == 0 {
            return deletedCount == 1 ? "Delete the only entry?" : "Delete all \(deletedCount) entries?"
        }
        return deletedCount == 1 ? "Delete the oldest entry?" : "Delete \(deletedCount) oldest entries?"
    }

    /// Short on purpose: the title already says how many entries go. The release and
    /// dev apps share the file, but only the owner has both, so the text does not say so.
    public var informativeText: String {
        "\(deletedCount == 1 ? "Its" : "Their") audio is deleted too. This can't be undone."
    }

    public var confirmButtonTitle: String {
        deletedCount == 1 ? "Delete 1 Entry" : "Delete \(deletedCount) Entries"
    }
}
