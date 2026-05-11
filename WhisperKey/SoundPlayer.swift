import AVFoundation
import Foundation
import os

@MainActor
final class SoundPlayer {
    enum Event: String, CaseIterable {
        case start, stop, done, error
    }

    private var urls: [Event: URL] = [:]
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
        }
    }

    func play(_ event: Event) {
        guard let url = urls[event] else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = delegateProxy
            player.prepareToPlay()
            active[ObjectIdentifier(player)] = player
            player.play()
        } catch {
            log.error("failed to play \(event.rawValue, privacy: .public).aif: \(String(describing: error), privacy: .public)")
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
