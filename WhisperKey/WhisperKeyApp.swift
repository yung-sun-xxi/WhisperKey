import SwiftUI
import AppKit

@main
struct WhisperKeyApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.menuBarSymbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Quit WhisperKey") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch coordinator.state {
        case .idle: return "Idle — tap Right Option to record"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .error(let message): return "Error: \(message)"
        }
    }
}

extension AppCoordinator {
    var menuBarSymbolName: String {
        switch state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .error: return "mic.slash"
        }
    }
}
