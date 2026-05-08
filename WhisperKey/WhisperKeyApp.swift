import SwiftUI

@main
struct WhisperKeyApp: App {
    var body: some Scene {
        MenuBarExtra("WhisperKey", systemImage: "mic") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
