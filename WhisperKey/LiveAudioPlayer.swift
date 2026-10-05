import AVFoundation
import Foundation
import Live
import os

/// Plays Live's spoken answers: PCM16 little-endian, 24 kHz, mono, as the Realtime API sends it.
///
/// Its own `AVAudioEngine`, used for output only. The engine's `inputNode` is never touched:
/// reading it would open the microphone a second time, and `AudioRecorder` is the single
/// microphone owner. The engine starts on the first chunk, not at launch.
///
/// Every scheduled buffer is counted; when the last outstanding one has played,
/// `onAllPlayed` fires on the main actor. `stop()` drops whatever is queued and does not
/// report it as played.
@MainActor
final class LiveAudioPlayer {
    /// Everything handed to `enqueue` has been played.
    var onAllPlayed: (() -> Void)?
    /// The engine could not start; nothing will be heard.
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isAttached = false
    private var outstandingBuffers = 0
    /// Bumped by `stop()` and by an engine reconfiguration, so completions of buffers that
    /// were flushed are not counted against the new queue.
    private var generation = 0
    private var configurationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "WhisperKey", category: "Live")

    init() {
        // Float32 is what the mixer takes; the PCM16 from the wire is converted per chunk.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(LivePCM.sampleRate),
            channels: AVAudioChannelCount(LivePCM.channelCount),
            interleaved: false
        ) else {
            fatalError("Failed to create 24 kHz mono Float32 AVAudioFormat")
        }
        self.format = format
    }

    /// Queues one chunk of the answer behind the ones already queued.
    func enqueue(_ pcm16: Data) {
        guard let buffer = Self.makeBuffer(pcm16, format: format) else { return }
        guard startEngineIfNeeded() else { return }

        outstandingBuffers += 1
        let generation = self.generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bufferPlayed(generation: generation)
            }
        }
        if !node.isPlaying {
            node.play()
        }
    }

    /// Stops at once and forgets the queue. The engine stays prepared for the next answer.
    func stop() {
        generation += 1
        outstandingBuffers = 0
        if isAttached {
            node.stop()
        }
    }

    // MARK: - Private

    private func bufferPlayed(generation: Int) {
        guard generation == self.generation, outstandingBuffers > 0 else { return }
        outstandingBuffers -= 1
        if outstandingBuffers == 0 {
            onAllPlayed?()
        }
    }

    private func startEngineIfNeeded() -> Bool {
        if !isAttached {
            engine.attach(node)
            // The main mixer resamples 24 kHz to whatever the output device runs at.
            engine.connect(node, to: engine.mainMixerNode, format: format)
            isAttached = true
            observeConfigurationChanges()
        }
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            log.error("Live playback engine failed to start: \(String(describing: error), privacy: .public)")
            onFailure?("Live could not play audio")
            return false
        }
    }

    /// The engine stops itself when the output device changes (headphones in or out). Its
    /// queued buffers are gone with it, so the answer counts as played rather than leaving
    /// the session waiting for completions that will never come; the next chunk restarts
    /// the engine on the new device.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.engineConfigurationChanged()
            }
        }
    }

    private func engineConfigurationChanged() {
        log.info("Live playback output changed; queued audio dropped")
        let hadOutstanding = outstandingBuffers > 0
        generation += 1
        outstandingBuffers = 0
        node.stop()
        if hadOutstanding {
            onAllPlayed?()
        }
    }

    private nonisolated static func makeBuffer(_ pcm16: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm16.count / LivePCM.bytesPerSample
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        pcm16.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))
                channel[frame] = Float(sample) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
