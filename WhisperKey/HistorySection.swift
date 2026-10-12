import AppKit
import SwiftUI
import HistoryStore
import ThemeKit

/// The popover's history (#161): a caps "History" header, the latest entries as
/// `ThemedListRow`s with dividers between them (a click copies, a shift-click or a failed
/// entry opens the reader), and the Full history and Clear history buttons.
struct HistorySection: View {
    @ObservedObject var history: HistoryStore
    let coordinator: AppCoordinator

    @Environment(\.themeTokens) private var tokens
    @State private var copiedID: UUID?
    @State private var ownerWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The source says "History"; the caps header shows it in capitals.
            Text("History")
                .font(tokens.type.capsHeader.font)
                .tracking(tokens.type.capsHeader.tracking)
                .textCase(.uppercase)
                .foregroundStyle(tokens.colors.secondaryText.color)
                .padding(.horizontal, tokens.spacing.panelTextEdge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: tokens.sizes.listRow)

            Group {
                if history.entries.isEmpty {
                    Text("No transcriptions yet")
                        .font(tokens.type.body.font)
                        .foregroundStyle(tokens.colors.secondaryText.color)
                        .padding(.horizontal, tokens.spacing.rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: tokens.sizes.listRow)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(history.entries) { entry in
                                HistoryInlineRow(
                                    entry: entry,
                                    copied: copiedID == entry.id,
                                    onCopy: { copy(entry: entry) },
                                    onOpenReadWindow: { openReadWindow(entry: entry) },
                                    onRetry: { coordinator.retryHistoryEntry(entry) }
                                )
                                if entry.id != history.entries.last?.id {
                                    PopoverDivider()
                                        .padding(.horizontal, tokens.spacing.rowPadding)
                                }
                            }
                        }
                    }
                    .frame(height: inlineListHeight)
                    .scrollIndicators(.visible)
                }
            }
            .padding(.horizontal, tokens.spacing.rowInset)
            .padding(.bottom, tokens.popover.listBottom)

            HStack(spacing: tokens.controlMetrics.rowControlGap) {
                ThemedPushButton("Full history") {
                    HistoryFullWindowController.show(history: history, coordinator: coordinator)
                }
                .disabled(history.entries.isEmpty)
                Spacer(minLength: 0)
                ThemedPushButton("Clear history", role: .destructive) {
                    ClearHistoryConfirmation.present(from: ownerWindow) {
                        history.clear()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, tokens.spacing.panelTextEdge)
            .padding(.bottom, tokens.popover.buttonsBottom)
        }
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
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

    private func openReadWindow(entry: HistoryEntry) {
        HistoryReadWindowController.show(entry: entry) {
            coordinator.retryHistoryEntry(entry)
        }
    }

    /// `visibleRows` list rows and the dividers between them; more scroll.
    private var inlineListHeight: CGFloat {
        let visibleRows = min(history.entries.count, tokens.popover.visibleRows)
        let dividerCount = max(visibleRows - 1, 0)
        return CGFloat(visibleRows) * tokens.sizes.listRow
            + CGFloat(dividerCount) * tokens.panels.popover.edgeWidth
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

/// One history entry: one line of text in `body`, a green check once copied, and
/// Retry on an entry that can be recognised again. A failed entry is a hatched row in
/// `secondaryText`.
private struct HistoryInlineRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onOpenReadWindow: () -> Void
    let onRetry: () -> Void
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        let recognized = entry.status == .recognized
        ThemedListRow(style: recognized ? .normal : .failed) {
            HStack(spacing: tokens.popover.rowGap) {
                HStack(spacing: tokens.popover.rowGap) {
                    Text(displayText)
                        .font(tokens.type.body.font)
                        .foregroundStyle((recognized ? tokens.colors.primaryText : tokens.colors.secondaryText).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if copied {
                        Image(systemName: "checkmark")
                            .font(tokens.type.caption.font)
                            .foregroundStyle(tokens.colors.success.color)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: handlePrimaryClick)
                .contextMenu {
                    if entry.canRetryRecognition {
                        Button("Retry", action: onRetry)
                    }
                    Button("Open in Window", action: onOpenReadWindow)
                    if entry.status == .recognized {
                        Button("Copy to Clipboard", action: onCopy)
                    }
                }
                .help(displayText)

                if entry.canRetryRecognition {
                    ThemedFailureButton("Retry", action: onRetry)
                }
            }
        }
    }

    private func handlePrimaryClick() {
        if entry.status != .recognized || NSEvent.modifierFlags.contains(.shift) {
            onOpenReadWindow()
        } else {
            onCopy()
        }
    }

    private var displayText: String {
        switch entry.status {
        case .recognized:
            entry.preview(maxLength: 240)
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
