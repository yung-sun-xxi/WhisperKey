import Foundation
import AudioRecorder

public struct EncodedAudio: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let fileExtension: String

    public init(data: Data, mimeType: String, fileExtension: String) {
        self.data = data
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }

    public var filename: String { "audio.\(fileExtension)" }
}

public enum AudioEncoderError: Error {
    case bufferTooLarge
}

/// For this slice the encoder simply wraps the captured 16-bit PCM in a WAV (RIFF) container.
/// Opus-in-OGG encoding (with WAV fallback) lands in a later issue.
public struct AudioEncoder: Sendable {
    public init() {}

    public func encode(_ buffer: AudioBuffer) throws -> EncodedAudio {
        let wav = try Self.makeWAV(
            pcm: buffer.samples,
            sampleRate: UInt32(buffer.sampleRate),
            channelCount: UInt16(buffer.channelCount),
            bitsPerSample: 16
        )
        return EncodedAudio(data: wav, mimeType: "audio/wav", fileExtension: "wav")
    }

    static func makeWAV(
        pcm: Data,
        sampleRate: UInt32,
        channelCount: UInt16,
        bitsPerSample: UInt16
    ) throws -> Data {
        let dataSize = pcm.count
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize
        guard chunkSize <= UInt32.max else { throw AudioEncoderError.bufferTooLarge }

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(chunkSize))
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))         // subchunk1Size for PCM
        data.appendLE(UInt16(1))          // audioFormat = PCM
        data.appendLE(channelCount)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)

        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(dataSize))
        data.append(pcm)

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
