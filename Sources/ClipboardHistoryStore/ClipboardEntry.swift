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

    public init(
        id: UUID = UUID(),
        text: String,
        capturedAt: Date,
        origin: ClipboardEntryOrigin = .otherApplication
    ) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.origin = origin
    }

    /// A single line short enough for a popup row.
    public func preview(maxLength: Int = 80) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > maxLength else { return oneLine }
        return oneLine.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "…"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case capturedAt
        case origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decode(String.self, forKey: .text)
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        // Present-if-absent with a default, so a file written before the origin field
        // existed still loads. Anything from back then was a hand copy.
        self.origin = try container.decodeIfPresent(ClipboardEntryOrigin.self, forKey: .origin) ?? .otherApplication
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(origin, forKey: .origin)
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
