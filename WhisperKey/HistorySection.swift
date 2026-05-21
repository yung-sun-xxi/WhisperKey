import AppKit
import SwiftUI
import HistoryStore

struct HistorySection: View {
    @ObservedObject var history: HistoryStore

    private static let visibleRowCount = 7
    private static let inlineRowHeight: CGFloat = 26

    @State private var copiedID: UUID?
    @State private var ownerWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(PopoverTypography.strongSectionTitle)
                    .foregroundColor(PopoverTypography.primaryColor)
                Spacer()
            }

            if history.entries.isEmpty {
                Text("No transcriptions yet")
                    .font(PopoverTypography.base)
                    .foregroundColor(PopoverTypography.secondaryColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryInlineRow(
                                entry: entry,
                                copied: copiedID == entry.id,
                                onCopy: { copy(entry: entry) },
                                onOpenReadWindow: { openReadWindow(entry: entry) }
                            )
                            .frame(height: Self.inlineRowHeight)
                            if entry.id != history.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: inlineListHeight)
                .scrollIndicators(.visible)
            }

            HStack(spacing: 8) {
                Button {
                    HistoryFullWindowController.show(history: history)
                } label: {
                    Text("Full history")
                        .font(PopoverTypography.button)
                }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
                Spacer()
                Button {
                    ClearHistoryConfirmation.present(from: ownerWindow) {
                        history.clear()
                    }
                } label: {
                    Text("Clear history")
                        .font(PopoverTypography.button)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
            }
        }
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
    }

    private func copy(entry: HistoryEntry) {
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

    private func openReadWindow(entry: HistoryEntry) {
        HistoryReadWindowController.show(entry: entry)
    }

    private var inlineListHeight: CGFloat {
        let visibleRows = min(history.entries.count, Self.visibleRowCount)
        let dividerCount = max(visibleRows - 1, 0)
        return (CGFloat(visibleRows) * Self.inlineRowHeight) + CGFloat(dividerCount)
    }
}

@MainActor
enum ClearHistoryConfirmation {
    static func present(from ownerWindow: NSWindow?, onClear: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Clear all transcription history?"
        alert.informativeText = "This permanently removes all stored transcriptions from this device"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear history")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.dropFirst().first?.keyEquivalent = "\u{1b}"

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onClear()
        }

        let resolvedOwnerWindow = ownerWindow ?? NSApp.keyWindow
        if let resolvedOwnerWindow, !resolvedOwnerWindow.styleMask.contains(.borderless) {
            alert.beginSheetModal(for: resolvedOwnerWindow) { response in
                Task { @MainActor in
                    handleResponse(response)
                }
            }
        } else {
            handleResponse(alert.runModal())
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

private struct HistoryInlineRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onOpenReadWindow: () -> Void

    var body: some View {
        Button(action: handlePrimaryClick) {
            HStack(spacing: 6) {
                Text(entry.preview(maxLength: 240))
                    .font(PopoverTypography.base)
                    .foregroundColor(PopoverTypography.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Window", action: onOpenReadWindow)
            Button("Copy to Clipboard", action: onCopy)
        }
        .help(entry.preview(maxLength: 240))
    }

    private func handlePrimaryClick() {
        if NSEvent.modifierFlags.contains(.shift) {
            onOpenReadWindow()
        } else {
            onCopy()
        }
    }
}
