import AppKit
import SwiftUI
import HistoryStore

struct HistorySection: View {
    @ObservedObject var history: HistoryStore

    @State private var copiedID: UUID?
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                if !history.entries.isEmpty {
                    Text("\(history.entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if history.entries.isEmpty {
                Text("No transcriptions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(history.entries) { entry in
                            HistoryRow(
                                entry: entry,
                                copied: copiedID == entry.id,
                                onCopy: { copy(entry: entry) },
                                onOpenReadWindow: { openReadWindow(entry: entry) }
                            )
                            if entry.id != history.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Spacer()
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

private struct HistoryRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onOpenReadWindow: () -> Void

    var body: some View {
        Button(action: handlePrimaryClick) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.preview())
                        .font(.system(.callout))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
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
            .padding(.horizontal, 4)
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
