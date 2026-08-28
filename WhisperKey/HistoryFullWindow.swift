import AppKit
import SwiftUI
import HistoryStore

@MainActor
enum HistoryFullWindowController {
    private static var window: NSWindow?
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

        let host = NSHostingController(rootView: HistoryFullView(history: history, coordinator: coordinator))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "WhisperKey History"
        window.setContentSize(NSSize(width: 560, height: 500))
        window.minSize = NSSize(width: 420, height: 320)
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

private struct HistoryFullView: View {
    @ObservedObject var history: HistoryStore
    let coordinator: AppCoordinator

    @State private var copiedID: UUID?
    @State private var ownerWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(countLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear history") {
                    ClearHistoryConfirmation.present(from: ownerWindow) {
                        history.clear()
                    }
                }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
            }

            if history.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryFullRow(
                                entry: entry,
                                copied: copiedID == entry.id,
                                onCopy: { copy(entry: entry) },
                                onOpen: {
                                    HistoryReadWindowController.show(entry: entry) {
                                        coordinator.retryHistoryEntry(entry)
                                    }
                                },
                                onRetry: { coordinator.retryHistoryEntry(entry) }
                            )
                            if entry.id != history.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .frame(minWidth: 420, minHeight: 320)
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
    }

    private var countLabel: String {
        let count = history.entries.count
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No transcriptions yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(entry: HistoryEntry) {
        guard entry.status == .recognized else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if copiedID == entry.id {
                copiedID = nil
            }
        }
    }
}

private struct HistoryFullRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayText)
                        .font(.system(.callout))
                        .foregroundStyle(entry.status == .recognized ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let language = entry.language, !language.isEmpty {
                            Text("·")
                            Text(language.uppercased())
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if copied {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .onTapGesture(perform: handlePrimaryClick)
            .contextMenu {
                if entry.canRetryRecognition {
                    Button("Retry", action: onRetry)
                }
                Button("Open in Window", action: onOpen)
                if entry.status == .recognized {
                    Button("Copy to Clipboard", action: onCopy)
                }
            }
            .help(displayText)

            if entry.canRetryRecognition {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }
        }
    }

    private func handlePrimaryClick() {
        if entry.status != .recognized || NSEvent.modifierFlags.contains(.shift) {
            onOpen()
        } else {
            onCopy()
        }
    }

    private var displayText: String {
        switch entry.status {
        case .recognized:
            entry.preview(maxLength: 320)
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
