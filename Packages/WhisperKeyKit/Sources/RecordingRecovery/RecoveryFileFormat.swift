import AudioRecorder
import Foundation

/// What a recovery file says about its recording, ahead of the audio.
public struct RecoveryHeader: Codable, Equatable, Sendable {
    /// Also the id of the history row this recording gets, on every path.
    public var recordingID: UUID
    public var startedAt: Date
    public var sampleRate: Double
    public var channelCount: UInt32
    public var providerID: String
    public var modelID: String?
    public var language: String?

    public init(
        recordingID: UUID,
        startedAt: Date,
        sampleRate: Double,
        channelCount: UInt32,
        providerID: String,
        modelID: String?,
        language: String?
    ) {
        self.recordingID = recordingID
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.providerID = providerID
        self.modelID = modelID
        self.language = language
    }
}

/// The bytes of a recovery file: a magic, a version, the header's length, the header as
/// JSON, then raw 16-bit little-endian PCM to the end of the file. Nothing after the
/// header is counted or closed, so a file cut off anywhere past it is still readable.
enum RecoveryFileFormat {
    private static let magic = Data("WKRECOVR".utf8)
    private static let version: UInt16 = 1
    private static let maxHeaderBytes = 64 * 1024

    static func encode(_ header: RecoveryHeader) -> Data {
        // A header of plain strings, numbers and a UUID always encodes.
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var data = magic
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    /// Nil when the header is cut off, foreign, or names a format no recording has. A torn
    /// last frame is dropped.
    static func decode(_ data: Data) -> (header: RecoveryHeader, audio: AudioBuffer)? {
        var rest = data[...]
        func take(_ count: Int) -> Data? {
            guard rest.count >= count else { return nil }
            defer { rest = rest.dropFirst(count) }
            return Data(rest.prefix(count))
        }
        guard
            take(magic.count) == magic,
            let versionBytes = take(2),
            versionBytes.littleEndianValue == UInt32(version),
            let lengthBytes = take(4),
            case let length = Int(lengthBytes.littleEndianValue),
            length <= maxHeaderBytes,
            let json = take(length),
            let header = try? JSONDecoder().decode(RecoveryHeader.self, from: json),
            (8_000...384_000).contains(header.sampleRate),
            (1...8).contains(header.channelCount)
        else { return nil }
        let frameBytes = 2 * Int(header.channelCount)
        let samples = Data(rest.prefix(rest.count / frameBytes * frameBytes))
        return (header, AudioBuffer(samples: samples, sampleRate: header.sampleRate, channelCount: header.channelCount))
    }
}

private extension Data {
    var littleEndianValue: UInt32 {
        enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
}
