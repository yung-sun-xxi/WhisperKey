import AppKit
import SwiftUI
import HistoryStore

struct HistorySection: View {
    @ObservedObject var history: HistoryStore

    static let inlineLimit = 10

    @State private var copiedID: UUID?
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
            }

            if history.entries.isEmpty {
                Text("No transcriptions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    let shown = Array(history.entries.prefix(Self.inlineLimit))
                    ForEach(shown) { entry in
                        HistoryInlineRow(
                            entry: entry,
                            copied: copiedID == entry.id,
                            onCopy: { copy(entry: entry) },
                            onOpenReadWindow: { openReadWindow(entry: entry) }
                        )
                        if entry.id != shown.last?.id {
                            Divider()
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Full History…") {
                    HistoryFullWindowController.show(history: history)
                }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
                Button("Clear history…") {
                    showingClearConfirmation = true
                }
                .controlSize(.small)
                .disabled(history.entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all transcription history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all stored transcriptions from this device.")
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
                    .font(.system(.callout))
                    .foregroundStyle(.primary)
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
            .padding(.horizontal, 2)
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
