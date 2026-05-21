import SwiftUI

@MainActor
@main
struct WhisperKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverContent()
                .environmentObject(appDelegate.coordinator)
        } label: {
            MenuBarExtraStatusLabel(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
