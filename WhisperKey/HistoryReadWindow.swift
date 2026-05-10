import AppKit
import SwiftUI
import HistoryStore

@MainActor
enum HistoryReadWindowController {
    private static var openWindows: [UUID: NSWindow] = [:]

    static func show(entry: HistoryEntry) {
        if let existing = openWindows[entry.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let formattedDate = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        let contentView = HistoryReadView(
            entry: entry,
            formattedDate: formattedDate,
            onClose: { close(id: entry.id) }
        )
        let host = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Transcription"
        window.setContentSize(NSSize(width: 480, height: 280))
        window.minSize = NSSize(width: 360, height: 220)
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

private struct HistoryReadView: View {
    let entry: HistoryEntry
    let formattedDate: String
    let onClose: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedDate)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let language = entry.language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }

            ScrollView {
                Text(entry.text)
                    .font(.system(.body, design: .default))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        didCopy = false
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
    }
}
