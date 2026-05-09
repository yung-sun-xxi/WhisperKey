import SwiftUI
import AppKit

@main
struct WhisperKeyApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            PopoverContent()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppCoordinator {
    var menuBarSymbolName: String {
        switch state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .error, .microphoneDenied, .accessibilityDenied: return "mic.slash"
        }
    }
}
