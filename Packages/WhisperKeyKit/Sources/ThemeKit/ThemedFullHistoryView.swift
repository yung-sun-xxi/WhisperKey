import AppKit
import SwiftUI

/// The full history window's content as drawn (#164): a count bar on `bar` between two
/// `divider` lines — the number of entries, its noun, and Clear history — then the list
/// area on `surface`: the entries as the popover's list rows, each with its absolute
/// timestamp, or the empty list's tray over one line.
///
/// Every size is `tokens.fullHistory` or a shared token; every colour and font a token.
/// The wording of each row (its text, its timestamp) is the caller's, and so are the
/// actions. Lives in ThemeKit rather than in the app so a test can host it.
public struct ThemedFullHistoryView: View {
    /// One entry, newest first.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// One line, already cut to `previewLength`, or the failure's wording.
        public let text: String
        /// When it was made, already formatted.
        public let timestamp: String
        /// A recognised entry is copied by a click; any other is opened.
        public let isRecognized: Bool
        /// Whether the row carries Retry.
        public let canRetry: Bool

        public init(id: UUID, text: String, timestamp: String, isRecognized: Bool, canRetry: Bool) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.isRecognized = isRecognized
            self.canRetry = canRetry
        }
    }

    /// How much of a recognised entry a row shows: the app's earlier length.
    public static let previewLength = 320
    /// How long the green check stays after a copy: the app's earlier 1.4 s.
    public static let copiedCheckNanoseconds: UInt64 = 1_400_000_000

    /// Today's count text, "1 entry" or "N entries", in its two drawn parts.
    public static func countParts(_ count: Int) -> (number: String, noun: String) {
        ("\(count)", count == 1 ? "entry" : "entries")
    }

    @Environment(\.themeTokens) private var tokens
    private let rows: [Row]
    private let copiedID: UUID?
    private let onClear: () -> Void
    private let onCopy: (UUID) -> Void
    private let onOpen: (UUID) -> Void
    private let onRetry: (UUID) -> Void

    public init(
        rows: [Row],
        copiedID: UUID?,
        onClear: @escaping () -> Void,
        onCopy: @escaping (UUID) -> Void,
        onOpen: @escaping (UUID) -> Void,
        onRetry: @escaping (UUID) -> Void
    ) {
        self.rows = rows
        self.copiedID = copiedID
        self.onClear = onClear
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onRetry = onRetry
    }

    public var body: some View {
        let history = tokens.fullHistory
        VStack(spacing: 0) {
            divider
            countBar
            divider
            listArea
        }
        .frame(
            minWidth: history.minContentSize.width,
            maxWidth: .infinity,
            minHeight: history.minContentSize.height,
            maxHeight: .infinity,
            alignment: .top
        )
        .background(tokens.colors.surface.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.fullHistory.dividerWidth)
    }

    /// The design's tab well turned into the count bar: the number, its noun, and Clear
    /// history, the drawn destructive push button, disabled when there is nothing to clear.
    private var countBar: some View {
        let history = tokens.fullHistory
        let parts = Self.countParts(rows.count)
        return HStack(spacing: history.countGap) {
            Text(parts.number)
                .font(history.count.font)
                .foregroundStyle(tokens.colors.primaryText.color)
            Text(parts.noun)
                .font(tokens.type.caption.font)
                .foregroundStyle(tokens.colors.secondaryText.color)
            Spacer(minLength: 0)
            ThemedPushButton("Clear history", role: .destructive, action: onClear)
                .fixedSize()
                .disabled(rows.isEmpty)
        }
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.sizes.actionBar)
        .background(tokens.colors.bar.color)
    }

    @ViewBuilder
    private var listArea: some View {
        let history = tokens.fullHistory
        if rows.isEmpty {
            emptyList
                .padding(.vertical, history.listPaddingVertical)
                .padding(.horizontal, history.listPaddingHorizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The padding is the content's, so rows scroll through it to the window's edge,
            // as the design's clipped list area lets them.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FullHistoryRow(
                            row: row,
                            copied: copiedID == row.id,
                            onCopy: onCopy,
                            onOpen: onOpen,
                            onRetry: onRetry
                        )
                    }
                }
                .padding(.vertical, history.listPaddingVertical)
                .padding(.horizontal, history.listPaddingHorizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The sheet's empty list: the tray in `mutedEdge` over one `body` line in
    /// `secondaryText`, centred both ways.
    private var emptyList: some View {
        let history = tokens.fullHistory
        return VStack(spacing: history.emptyGap) {
            Image(systemName: "tray")
                .font(history.emptyGlyph.font)
                .foregroundStyle(tokens.colors.mutedEdge.color)
            Text("No transcriptions yet")
                .font(tokens.type.body.font)
                .foregroundStyle(tokens.colors.secondaryText.color)
        }
    }
}

/// One entry: its text in one line, the green check once copied, Retry on an entry that
/// can be recognised again, and the timestamp last. The popover's row, with no selection
/// bar: this window has no keyboard selection to mark.
private struct FullHistoryRow: View {
    let row: ThemedFullHistoryView.Row
    let copied: Bool
    let onCopy: (UUID) -> Void
    let onOpen: (UUID) -> Void
    let onRetry: (UUID) -> Void
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        let history = tokens.fullHistory
        ThemedListRow(style: row.isRecognized ? .normal : .failed) {
            HStack(spacing: history.rowGap) {
                HStack(spacing: history.failedRowGap) {
                    HStack(spacing: history.rowGap) {
                        Text(row.text)
                            .font(tokens.type.body.font)
                            .foregroundStyle((row.isRecognized ? tokens.colors.primaryText : tokens.colors.secondaryText).color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if copied {
                            Image(systemName: "checkmark")
                                .font(tokens.type.caption.font)
                                .foregroundStyle(tokens.colors.success.color)
                        }
                    }
                    .modifier(RowActions(row: row, onCopy: onCopy, onOpen: onOpen, onRetry: onRetry))

                    if row.canRetry {
                        ThemedFailureButton("Retry") { onRetry(row.id) }
                    }
                }

                Text(row.timestamp)
                    .font(history.timestamp.font)
                    .foregroundStyle(tokens.colors.secondaryText.color)
                    .lineLimit(1)
                    .fixedSize()
                    .modifier(RowActions(row: row, onCopy: onCopy, onOpen: onOpen, onRetry: onRetry))
            }
        }
    }
}

/// What a row does, wherever on it the pointer is (Retry aside): a click copies a
/// recognised entry, a shift-click or a click on any other opens it; the context menu
/// and the tooltip are the popover's.
private struct RowActions: ViewModifier {
    let row: ThemedFullHistoryView.Row
    let onCopy: (UUID) -> Void
    let onOpen: (UUID) -> Void
    let onRetry: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: primaryClick)
            .contextMenu {
                if row.canRetry {
                    Button("Retry") { onRetry(row.id) }
                }
                Button("Open in Window") { onOpen(row.id) }
                if row.isRecognized {
                    Button("Copy to Clipboard") { onCopy(row.id) }
                }
            }
            .help(row.text)
    }

    private func primaryClick() {
        if !row.isRecognized || NSEvent.modifierFlags.contains(.shift) {
            onOpen(row.id)
        } else {
            onCopy(row.id)
        }
    }
}
