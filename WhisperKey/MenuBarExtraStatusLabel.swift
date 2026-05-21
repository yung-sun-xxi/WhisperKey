import Combine
import SwiftUI

struct MenuBarExtraStatusLabel: View {
    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55

    @ObservedObject var coordinator: AppCoordinator
    @State private var blinkOn = true

    var body: some View {
        HStack(spacing: 4) {
            Image("MenuBarIcon")
                .renderingMode(.template)

            if case .recording = coordinator.state {
                Text(coordinator.recordingTimerText)
                    .foregroundStyle(timerColor)
                    .monospacedDigit()
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard coordinator.recordingElapsed >= Self.redThreshold else {
                blinkOn = true
                return
            }

            blinkOn.toggle()
        }
    }

    private var timerColor: Color {
        if coordinator.recordingElapsed >= Self.redThreshold {
            return blinkOn ? .red : .red.opacity(0.25)
        }

        if coordinator.recordingElapsed >= Self.yellowThreshold {
            return .yellow
        }

        return Color(nsColor: .labelColor)
    }
}
