import SwiftUI

struct LaunchAtLoginToggle: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("",
                   isOn: Binding(
                       get: { coordinator.launchAtLoginEnabled },
                       set: { coordinator.setLaunchAtLogin($0) }
                   )
            )
            .labelsHidden()
            .toggleStyle(.switch)

            if let message = coordinator.launchAtLoginError {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
