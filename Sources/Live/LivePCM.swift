import Foundation

/// The one audio format Live speaks in both directions: PCM16, little-endian, mono, 24 kHz —
/// the Realtime API's `audio/pcm` at rate 24000.
public enum LivePCM {
    public static let sampleRate = 24_000
    public static let channelCount = 1
    public static let bytesPerSample = 2
    public static let bytesPerSecond = sampleRate * channelCount * bytesPerSample

    /// Seconds of audio in `byteCount` bytes.
    public static func duration(ofByteCount byteCount: Int) -> TimeInterval {
        TimeInterval(byteCount) / TimeInterval(bytesPerSecond)
    }

    /// Bytes for `duration` seconds, rounded down to whole samples.
    public static func byteCount(for duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let samples = Int((duration * TimeInterval(sampleRate)).rounded(.down))
        return samples * channelCount * bytesPerSample
    }

    /// Whole milliseconds in `byteCount` bytes, counting complete samples only. This is the
    /// unit of `audio_end_ms` when a played answer is truncated.
    public static func milliseconds(ofByteCount byteCount: Int) -> Int {
        let samples = max(0, byteCount) / (channelCount * bytesPerSample)
        return samples * 1_000 / sampleRate
    }

    /// A chunk as the `audio` field of `input_audio_buffer.append` carries it.
    public static func base64(_ chunk: Data) -> String {
        chunk.base64EncodedString()
    }
}
