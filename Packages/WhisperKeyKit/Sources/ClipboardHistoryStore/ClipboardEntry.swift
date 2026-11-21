import Foundation

/// Where a clipboard entry came from.
///
/// This cannot be worked out when the entry is read: the monitor only ever sees that the
/// pasteboard's change counter moved. It has to be produced where the text is written —
/// see `ClipboardOriginMarker`.
public enum ClipboardEntryOrigin: String, Codable, Equatable, Sendable {
    /// Copied by some other application — an ordinary hand copy.
    case otherApplication
    /// Written to the clipboard by WhisperKey itself.
    case whisperKey
}

public struct ClipboardEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let capturedAt: Date
    public let origin: ClipboardEntryOrigin
    /// The pasteboard item carried the password managers' concealed marker.
    ///
    /// Recorded like any other entry and shown in the popup like any other entry — but
    /// never written to disk. See `ClipboardHistoryStore.persistable(_:)`.
    public let isConcealed: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        capturedAt: Date,
        origin: ClipboardEntryOrigin = .otherApplication,
        isConcealed: Bool = false
    ) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.origin = origin
        self.isConcealed = isConcealed
    }

    /// A single line short enough for a popup row.
    ///
    /// Every run of whitespace — newlines, tabs, indentation, blank lines — becomes one
    /// space. Replacing each newline with its own space would be enough to make the text
    /// one line, but a dictated paragraph or an indented code fragment would then arrive
    /// as words separated by gaps, and the character budget would be spent on whitespace
    /// the reader cannot see.
    public func preview(maxLength: Int = 80) -> String {
        let oneLine = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard oneLine.count > maxLength else { return oneLine }
        return oneLine.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case capturedAt
        case origin
        case isConcealed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        // Present-if-absent with a default, so a file written before the origin field
        // existed still loads. Anything from back then was a hand copy.
        self.origin = try container.decodeIfPresent(ClipboardEntryOrigin.self, forKey: .origin) ?? .otherApplication
        // Same rule for the concealed flag. Nothing written before this field existed was
        // concealed — a concealed entry could not have reached the file in the first
        // place — so absent means `false`.
        self.isConcealed = try container.decodeIfPresent(Bool.self, forKey: .isConcealed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(origin, forKey: .origin)
        try container.encode(isConcealed, forKey: .isConcealed)
    }
}

/// The private pasteboard type WhisperKey writes alongside its own strings.
///
/// Attribution is produced at the point of writing, never inferred at the point of
/// reading. A marker riding on the pasteboard item itself — rather than an "the next
/// change is mine" flag handed to the monitor — is what survives the gap between the
/// write and the monitor's next poll, which can be up to a full poll interval and can
/// contain a hand copy of the user's own.
public enum ClipboardOriginMarker {
    /// Written alongside `public.utf8-plain-text` by WhisperKey's clipboard-output path.
    public static let pasteboardType = "com.yung-sun-xxi.WhisperKey.clipboard-origin"
    /// Payload of that type. The value carries no meaning; presence of the type is the signal.
    public static let markerValue = "whisperkey"

    public static func origin(forTypes types: Set<String>) -> ClipboardEntryOrigin {
        types.contains(pasteboardType) ? .whisperKey : .otherApplication
    }
}
