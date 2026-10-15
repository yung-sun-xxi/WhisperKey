import SwiftUI

/// The three figures of a Usage by model row, already formatted by the caller.
public struct UsageBreakdownFigures: Equatable, Sendable {
    public let words: String
    public let audio: String
    public let cost: String

    public init(words: String, audio: String, cost: String) {
        self.words = words
        self.audio = audio
        self.cost = cost
    }
}

/// One model in the Usage by model window: its name and its figures. `id` is the caller's
/// key for it.
public struct UsageBreakdownLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let figures: UsageBreakdownFigures

    public init(id: String, title: String, figures: UsageBreakdownFigures) {
        self.id = id
        self.title = title
        self.figures = figures
    }
}

/// The Usage by model window's content as drawn (#184): a `divider` line under the
/// titlebar; the caller's period picker on a `bar` band; another `divider` line; then a
/// `card` holding the table — the caps header over an `edge` line, one `listRow` per
/// model with `edge` hairlines between them, and Total in `title` type under an `edge`
/// line across the card. With no rows the card holds "No usage in this period." alone.
///
/// Every size is `tokens.usageBreakdown` or a shared token; every colour and font a
/// token. The rows and the picker are the caller's. Lives in ThemeKit rather than in the
/// app so a test can host it.
public struct ThemedUsageBreakdownView<Picker: View>: View {
    @Environment(\.themeTokens) private var tokens
    private let rows: [UsageBreakdownLine]
    private let total: UsageBreakdownFigures
    private let picker: Picker

    /// - Parameters:
    ///   - rows: The models in the period, in the order shown. Empty draws the empty card.
    ///   - total: The period's figures across every model.
    ///   - picker: The period picker, drawn on the band.
    public init(
        rows: [UsageBreakdownLine],
        total: UsageBreakdownFigures,
        @ViewBuilder picker: () -> Picker
    ) {
        self.rows = rows
        self.total = total
        self.picker = picker()
    }

    public var body: some View {
        VStack(spacing: 0) {
            line(tokens.colors.divider.color)
            band
            line(tokens.colors.divider.color)
            content
        }
        .frame(width: tokens.usageBreakdown.contentWidth)
        .background(tokens.colors.surface.color)
    }

    private func line(_ colour: Color) -> some View {
        Rectangle()
            .fill(colour)
            .frame(height: tokens.controlMetrics.edgeWidth)
    }

    private var band: some View {
        picker
            .padding(.vertical, tokens.usageBreakdown.barPaddingVertical)
            .padding(.horizontal, tokens.spacing.windowTextEdge)
            .frame(maxWidth: .infinity)
            .background(tokens.colors.bar.color)
    }

    private var content: some View {
        let metrics = tokens.usageBreakdown
        return Group {
            if rows.isEmpty {
                emptyCard
            } else {
                table
            }
        }
        .padding(.top, metrics.contentPaddingTop)
        .padding(.bottom, metrics.contentPaddingBottom)
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous)
    }

    private var emptyCard: some View {
        let metrics = tokens.usageBreakdown
        return Text("No usage in this period.")
            .font(tokens.type.body.font)
            .foregroundStyle(tokens.colors.secondaryText.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, metrics.emptyPaddingVertical)
            .padding(.horizontal, metrics.emptyPaddingHorizontal)
            .background(tokens.colors.card.color, in: cardShape)
    }

    /// The header and its line, the models with hairlines inset by the row padding
    /// between them, then a line across the whole card and Total.
    private var table: some View {
        let metrics = tokens.usageBreakdown
        return VStack(spacing: 0) {
            header
            line(tokens.colors.edge.color)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    line(tokens.colors.edge.color)
                        .padding(.horizontal, tokens.spacing.rowPadding)
                }
                tableRow(title: row.title, figures: row.figures)
                    .font(tokens.type.body.font)
            }
            line(tokens.colors.edge.color)
                .padding(.horizontal, -metrics.cardInset)
            tableRow(title: "Total", figures: total)
                .font(tokens.type.title.font)
        }
        .padding(.horizontal, metrics.cardInset)
        .padding(.bottom, metrics.cardInset)
        .background(tokens.colors.card.color, in: cardShape)
    }

    private var header: some View {
        columns(
            Text("Model"),
            Text("Words"),
            Text("Audio"),
            Text("Cost")
        )
        .font(tokens.type.capsHeader.font)
        .tracking(tokens.type.capsHeader.tracking)
        .textCase(.uppercase)
        .foregroundStyle(tokens.colors.secondaryText.color)
        .frame(height: tokens.sizes.listRow)
        .accessibilityElement(children: .combine)
    }

    private func tableRow(title: String, figures: UsageBreakdownFigures) -> some View {
        columns(
            Text(title),
            Text(figures.words),
            Text(figures.audio),
            Text(figures.cost)
        )
        .monospacedDigit()
        .foregroundStyle(tokens.colors.primaryText.color)
        .frame(height: tokens.sizes.listRow)
    }

    /// The model column takes what the three figure columns leave; it truncates on one
    /// line, and the figures end at the row's trailing padding.
    private func columns(_ name: Text, _ words: Text, _ audio: Text, _ cost: Text) -> some View {
        let metrics = tokens.usageBreakdown
        return HStack(spacing: metrics.columnGap) {
            name
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            figure(words, width: metrics.wordsColumn)
            figure(audio, width: metrics.audioColumn)
            figure(cost, width: metrics.costColumn)
        }
        .padding(.horizontal, tokens.spacing.rowPadding)
        .frame(maxWidth: .infinity)
    }

    /// A figure never truncates: one wider than its column runs into the gap before it.
    private func figure(_ text: Text, width: CGFloat) -> some View {
        text
            .lineLimit(1)
            .fixedSize()
            .frame(width: width, alignment: .trailing)
    }
}
