import SwiftUI
import ThemeKit

struct LaunchAtLoginToggle: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        // Trailing, so the switch stays at the row's right edge when an error shows.
        VStack(alignment: .trailing, spacing: tokens.settingsWindow.errorLineGap) {
            ThemedToggle(
                "Launch at login",
                isOn: Binding(
                    get: { coordinator.launchAtLoginEnabled },
                    set: { coordinator.setLaunchAtLogin($0) }
                )
            )

            if let message = coordinator.launchAtLoginError {
                Text(message)
                    .font(tokens.type.fieldCaption.font)
                    .foregroundStyle(tokens.colors.failureText.color)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
