import AppKit
import Combine
import SwiftUI
import ThemeKit
import HistoryStore

@MainActor
enum HistoryFullWindowController {
    private static var window: NSWindow?
    private static var themeFollower: AnyCancellable?
    private static let delegate = WindowDelegate()

    static var relatedWindow: NSWindow? {
        window
    }

    static func show(history: HistoryStore, coordinator: AppCoordinator) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            register(existing)
            return
        }

        ThemeTokensSource.shared.follow(coordinator.settings)
        let host = NSHostingController(rootView: ThemedRoot("fullHistory") {
            HistoryFullView(history: history, coordinator: coordinator)
        })
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "WhisperKey History"
        // Settings' chrome and the tokens' size, then the theme's colours on every switch.
        ThemedFullHistoryWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)
        themeFollower = ThemedFullHistoryWindow.follow(ThemeTokensSource.shared, window: window)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.delegate = delegate

        Self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        register(window)
    }

    static func hide() {
        TransientWindowStack.shared.unregister(id: "fullHistory")

        guard let window else { return }

        window.orderOut(nil)
    }

    static func windowDidClose() {
        TransientWindowStack.shared.unregister(id: "fullHistory")
        themeFollower = nil
        window = nil
    }

    private static func register(_ window: NSWindow) {
        TransientWindowStack.shared.register(
            id: "fullHistory",
            layer: .secondary,
            window: window
        ) {
            HistoryFullWindowController.hide()
        }
    }
}

@MainActor
private final class WindowDelegate: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            HistoryFullWindowController.windowDidClose()
        }
    }
}

/// The store's entries as rows for `ThemedFullHistoryView`, which draws them (#164), and
/// what its actions do: copy, open the reader, retry, and Clear history after the alert.
private struct HistoryFullView: View {
    @ObservedObject var history: HistoryStore
    let coordinator: AppCoordinator

    @State private var copiedID: UUID?
    @State private var ownerWindow: NSWindow?

    var body: some View {
        ThemedFullHistoryView(
            rows: history.entries.map(row),
            copiedID: copiedID,
            onClear: {
                ClearHistoryConfirmation.present(from: ownerWindow) {
                    history.clear()
                }
            },
            onCopy: { id in
                if let entry = entry(id) { copy(entry) }
            },
            onOpen: { id in
                if let entry = entry(id) { open(entry) }
            },
            onRetry: { id in
                if let entry = entry(id) { coordinator.retryHistoryEntry(entry) }
            }
        )
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
    }

    private func row(_ entry: HistoryEntry) -> ThemedFullHistoryView.Row {
        ThemedFullHistoryView.Row(
            id: entry.id,
            text: displayText(entry),
            timestamp: HistoryTimestamp.string(from: entry.createdAt),
            isRecognized: entry.status == .recognized,
            canRetry: entry.canRetryRecognition
        )
    }

    private func entry(_ id: UUID) -> HistoryEntry? {
        history.entries.first { $0.id == id }
    }

    private func open(_ entry: HistoryEntry) {
        HistoryReadWindowController.show(entry: entry) {
            coordinator.retryHistoryEntry(entry)
        }
    }

    private func copy(_ entry: HistoryEntry) {
        guard entry.status == .recognized else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: ThemedFullHistoryView.copiedCheckNanoseconds)
            if copiedID == entry.id {
                copiedID = nil
            }
        }
    }

    private func displayText(_ entry: HistoryEntry) -> String {
        switch entry.status {
        case .recognized:
            entry.preview(maxLength: ThemedFullHistoryView.previewLength)
        case .pendingRecognition:
            "File to recognize"
        case .noSpeechDetected:
            "No speech detected"
        case .silentAudio:
            "No microphone audio captured"
        case .captureFailed:
            entry.text.isEmpty ? "Audio capture failed" : entry.text
        }
    }
}
