import AppKit
import Combine
import SwiftUI
import ThemeKit
import HistoryStore

@MainActor
enum HistoryReadWindowController {
    private static var openWindows: [UUID: NSWindow] = [:]
    private static var themeFollowers: [UUID: AnyCancellable] = [:]

    /// The reader open on `id`, for the Debug build's snapshot hook.
    static func window(for id: UUID) -> NSWindow? {
        openWindows[id]
    }

    static func show(entry: HistoryEntry, onRetry: (() -> Void)? = nil) {
        if let existing = openWindows[entry.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = HistoryReadView(
            entry: entry,
            onRetry: onRetry,
            onClose: { close(id: entry.id) }
        )
        let host = NSHostingController(rootView: ThemedRoot("reader") { contentView })

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Transcription"
        // Settings' chrome and the tokens' size, then the theme's colours on every switch.
        ThemedHistoryReaderWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)
        themeFollowers[entry.id] = ThemedHistoryReaderWindow.follow(ThemeTokensSource.shared, window: window)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.delegate = WindowCloseDelegate.shared
        WindowCloseDelegate.shared.register(id: entry.id, window: window)

        openWindows[entry.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close(id: UUID) {
        themeFollowers.removeValue(forKey: id)
        guard let window = openWindows.removeValue(forKey: id) else { return }
        window.close()
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    private var idsByWindow: [ObjectIdentifier: UUID] = [:]

    func register(id: UUID, window: NSWindow) {
        idsByWindow[ObjectIdentifier(window)] = id
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            self.idsByWindow.removeValue(forKey: ObjectIdentifier(window))
        }
    }
}

/// The entry as `ThemedHistoryReaderView` shows it (#165): the date in the system's
/// format, the language, the text or its failure's wording, and what Copy, Retry and Close
/// do. It draws nothing itself.
private struct HistoryReadView: View {
    let entry: HistoryEntry
    let onRetry: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        ThemedHistoryReaderView(
            date: entry.createdAt.formatted(date: .abbreviated, time: .shortened),
            language: entry.language,
            text: displayText,
            isRecognized: entry.status == .recognized,
            canRetry: entry.canRetryRecognition && onRetry != nil,
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            },
            onRetry: { onRetry?() },
            onClose: onClose
        )
    }

    private var displayText: String {
        switch entry.status {
        case .recognized:
            entry.text
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
