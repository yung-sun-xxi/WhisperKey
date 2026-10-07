import AVFoundation
import Foundation
import os

@MainActor
final class SoundPlayer {
    enum Event: String, CaseIterable {
        case start, stop, done, error
    }

    private var urls: [Event: URL] = [:]
    /// One player per event, already through `prepareToPlay()`, so a play
    /// does not wait on decoding the file.
    private var ready: [Event: AVAudioPlayer] = [:]
    private var active: [ObjectIdentifier: AVAudioPlayer] = [:]
    private let delegateProxy = DelegateProxy()
    private let log = Logger(subsystem: "WhisperKey", category: "SoundPlayer")

    init(bundle: Bundle = .main) {
        delegateProxy.owner = self
        for event in Event.allCases {
            guard let url = bundle.url(forResource: event.rawValue, withExtension: "aif", subdirectory: "Sounds")
                ?? bundle.url(forResource: event.rawValue, withExtension: "aif")
            else {
                log.error("missing sound resource \(event.rawValue, privacy: .public).aif")
                continue
            }
            urls[event] = url
            ready[event] = makePreparedPlayer(for: event)
        }
    }

    /// Plays the ready player, then readies the next one, so a second play
    /// of the same event while the first is still sounding gets its own.
    func play(_ event: Event) {
        guard let player = ready.removeValue(forKey: event) ?? makePreparedPlayer(for: event) else { return }
        active[ObjectIdentifier(player)] = player
        player.play()
        Task { @MainActor [weak self] in
            guard let self, self.ready[event] == nil else { return }
            self.ready[event] = self.makePreparedPlayer(for: event)
        }
    }

    private func makePreparedPlayer(for event: Event) -> AVAudioPlayer? {
        guard let url = urls[event] else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = delegateProxy
            player.volume = event == .error ? 0.1 : 1
            player.prepareToPlay()
            return player
        } catch {
            log.error("failed to load \(event.rawValue, privacy: .public).aif: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    fileprivate func release(_ player: AVAudioPlayer) {
        active.removeValue(forKey: ObjectIdentifier(player))
    }

    private final class DelegateProxy: NSObject, AVAudioPlayerDelegate {
        weak var owner: SoundPlayer?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
            Task { @MainActor [weak owner] in
                owner?.release(player)
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
            Task { @MainActor [weak owner] in
                owner?.release(player)
            }
        }
    }
}
