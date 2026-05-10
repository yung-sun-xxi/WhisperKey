import SwiftUI
import AppKit

@main
struct WhisperKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            MenuBarIcon()
            if case .recording = coordinator.state {
                RecordingTimerLabel(
                    text: coordinator.recordingTimerText,
                    elapsed: coordinator.recordingElapsed
                )
            }
        }
    }
}

private struct RecordingTimerLabel: View {
    let text: String
    let elapsed: TimeInterval

    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55

    @State private var blinkOn = true

    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .opacity(shouldBlink && !blinkOn ? 0.25 : 1.0)
            .onAppear { updateBlinkAnimation() }
            .onChange(of: shouldBlink) { _, _ in updateBlinkAnimation() }
    }

    private var color: Color {
        if elapsed >= Self.redThreshold { return .red }
        if elapsed >= Self.yellowThreshold { return .yellow }
        return .primary
    }

    private var shouldBlink: Bool { elapsed >= Self.redThreshold }

    private func updateBlinkAnimation() {
        if shouldBlink {
            blinkOn = true
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                blinkOn = false
            }
        } else {
            blinkOn = true
        }
    }
}

private struct MenuBarIcon: View {
    var body: some View {
        Image("MenuBarIcon")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(height: 18)
    }
}
