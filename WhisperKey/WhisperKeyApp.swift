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
            coordinator.menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppCoordinator {
    @ViewBuilder
    var menuBarIcon: some View {
        switch state {
        case .idle, .transcribing:
            Image("MenubarIcon")
                .renderingMode(.template)
        case .recording:
            Image(systemName: "mic.fill")
        case .error, .microphoneDenied, .accessibilityDenied:
            Image(systemName: "mic.slash")
        }
    }
}
