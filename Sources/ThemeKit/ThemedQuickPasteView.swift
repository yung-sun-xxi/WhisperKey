import QuickPaste
import SwiftUI

/// The quick paste popup as drawn (#166): the shared floating-panel shell, a header bar
/// with the caps "Clipboard" label and a separator under it, and the entries as list
/// rows, the one under the pointer selected.
///
/// Every size here is the `QuickPasteMetrics` the controller also hands the hit test, or
/// a token; every colour and font is a token. Lives in ThemeKit rather than in the app so
/// a test can host it and hold what it draws to `QuickPasteLayout`.
///
/// The panel takes no mouse events, so the selection is the caller's (`selectedID`),
/// never the row's own hover.
public struct ThemedQuickPasteView: View {
    /// The symbol of a hand-copied entry, the ⌘ of the Cmd-C that copied it. One name, so
    /// changing it is a one-line swap.
    public static let copiedSymbol = "command"
    /// The symbol of a dictated entry.
    public static let dictatedSymbol = "waveform"

    /// One entry, in the order it appears from the top of the panel down.
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Marker: Equatable, Sendable {
            /// Written to the clipboard by WhisperKey: a transcription.
            case dictated
            /// Copied by hand in another application.
            case copied
        }

        public let id: UUID
        /// One line, already cut to the preview length.
        public let text: String
        public let marker: Marker

        public init(id: UUID, text: String, marker: Marker) {
            self.id = id
            self.text = text
            self.marker = marker
        }
    }

    @Environment(\.themeTokens) private var tokens
    private let metrics: QuickPasteMetrics
    private let rows: [Row]
    private let selectedID: UUID?

    public init(metrics: QuickPasteMetrics, rows: [Row], selectedID: UUID?) {
        self.metrics = metrics
        self.rows = rows
        self.selectedID = selectedID
    }

    public var body: some View {
        ThemedPanelShell(.quickPaste) {
            VStack(alignment: .leading, spacing: 0) {
                // The bar: `panelBar` tall on the `bar` fill, the label at the panel text
                // edge. The source says "Clipboard"; the caps header shows it in capitals,
                // as the popover's "History".
                Text("Clipboard")
                    .font(tokens.type.capsHeader.font)
                    .tracking(tokens.type.capsHeader.tracking)
                    .textCase(.uppercase)
                    .foregroundStyle(tokens.colors.secondaryText.color)
                    .padding(.horizontal, tokens.spacing.panelTextEdge)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: metrics.headerHeight)
                    .background(tokens.colors.bar.color)

                // The separator under the bar.
                Rectangle()
                    .fill(tokens.colors.divider.color)
                    .frame(height: metrics.separatorHeight)

                // A stack, not a `Group`: a `Group`'s padding would land on every row.
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("Clipboard history is empty")
                            .font(tokens.type.body.font)
                            .foregroundStyle(tokens.colors.secondaryText.color)
                            .lineLimit(1)
                            .padding(.horizontal, tokens.spacing.rowPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: metrics.rowHeight)
                    } else {
                        ForEach(rows) { row in
                            QuickPasteRowView(row: row, isSelected: row.id == selectedID)
                                // A fixed height, because the hit test computes row bands
                                // from the same number. A row that sized itself to its
                                // content would put the highlight and the choice on
                                // different rows.
                                .frame(height: metrics.rowHeight)
                        }
                    }
                }
                .padding(metrics.rowInset)
            }
            // Clear of the shell's edge, which `ThemedPanelShell` draws inside the shape:
            // the bar starts under the top edge rather than behind it, as the design's
            // border-box lays it out.
            .padding(metrics.edgeWidth)
            .frame(width: metrics.width, alignment: .topLeading)
        }
    }
}

/// One entry: its marker, then its text in one line cut at the tail.
private struct QuickPasteRowView: View {
    let row: ThemedQuickPasteView.Row
    let isSelected: Bool
    @Environment(\.themeTokens) private var tokens

    private var isDictated: Bool { row.marker == .dictated }

    var body: some View {
        let marker = tokens.quickPasteMarker
        ThemedListRow(isSelected: isSelected) {
            HStack(alignment: .firstTextBaseline, spacing: marker.gap) {
                // Dictated and hand-copied entries differ by shape — the waveform's bars
                // against the ⌘'s loops — both in `secondaryText`, so five similar
                // fragments can be told apart without reading them.
                Image(systemName: isDictated ? ThemedQuickPasteView.dictatedSymbol : ThemedQuickPasteView.copiedSymbol)
                    .font(marker.font.font)
                    .foregroundStyle(tokens.colors.secondaryText.color)
                    .frame(width: marker.width)
                    .accessibilityLabel(isDictated ? "Dictated" : "Copied")
                Text(row.text)
                    .font(tokens.type.body.font)
                    .foregroundStyle(tokens.colors.primaryText.color)
                    // One line, cut at the tail. Together with the fixed width this is
                    // what stops a long entry widening or wrapping the panel — the window
                    // is sized from `QuickPasteLayout`, so text that wanted more room
                    // would be clipped rather than granted it.
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }
}
