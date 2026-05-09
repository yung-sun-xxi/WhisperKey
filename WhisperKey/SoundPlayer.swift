import AVFoundation
import Foundation
import os

@MainActor
final class SoundPlayer {
    enum Event: String, CaseIterable {
        case start, stop, done, error
    }

    private var players: [Event: AVAudioPlayer] = [:]
    private let log = Logger(subsystem: "WhisperKey", category: "SoundPlayer")

    init(bundle: Bundle = .main) {
        for event in Event.allCases {
            guard let url = bundle.url(forResource: event.rawValue, withExtension: "aif", subdirectory: "Sounds")
                ?? bundle.url(forResource: event.rawValue, withExtension: "aif")
            else {
                log.error("missing sound resource \(event.rawValue, privacy: .public).aif")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[event] = player
            } catch {
                log.error("failed to load \(event.rawValue, privacy: .public).aif: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func play(_ event: Event) {
        guard let player = players[event] else { return }
        player.currentTime = 0
        player.play()
    }
}
