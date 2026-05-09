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
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 4) {
            MenuBarIcon(state: coordinator.state)
            if case .recording = coordinator.state {
                Text(coordinator.recordingTimerText)
                    .font(.system(.body, design: .rounded).monospacedDigit())
            }
        }
    }
}

private struct MenuBarIcon: View {
    let state: AppCoordinator.AppState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "mic")
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
        case .error, .microphoneDenied, .accessibilityDenied:
            Image(systemName: "mic.slash")
                .foregroundStyle(.yellow)
        }
    }
}
