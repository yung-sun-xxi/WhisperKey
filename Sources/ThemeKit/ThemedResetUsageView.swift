import SwiftUI

/// One model in the Reset usage window: what its row says and whether it is the model in
/// use. `id` is the caller's key for it.
public struct ResetUsageRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isCurrent: Bool

    public init(id: String, title: String, isCurrent: Bool) {
        self.id = id
        self.title = title
        self.isCurrent = isCurrent
    }
}

/// The Reset usage window's content as drawn (#183): a `divider` line under the titlebar;
/// the lead line in `secondaryText`; a `card` holding a Select all row, a hairline and one
/// row per model, each with a drawn checkbox and the model in use marked by a keycap-grey
/// "Current" pill; and the action bar on `bar` under another `divider` line with Cancel,
/// then "Reset selected…", both grey push buttons, the second off while nothing is ticked.
///
/// Every size is `tokens.resetUsage` or a shared token; every colour and font a token.
/// The rows are the caller's. "Reset selected…" does not reset: it hands the selection to
/// `onRequestReset`, which asks first. Lives in ThemeKit rather than in the app so a test
/// can host it.
public struct ThemedResetUsageView: View {
    /// What the Select all box shows.
    public enum SelectAllState: Equatable, Sendable {
        case none
        case some
        case all
    }

    public static func selectAllState(selected: Int, total: Int) -> SelectAllState {
        guard total > 0, selected > 0 else { return .none }
        return selected >= total ? .all : .some
    }

    /// The Select all row's words: it offers to clear once everything is ticked.
    public static func selectAllTitle(selected: Int, total: Int) -> String {
        selectAllState(selected: selected, total: total) == .all ? "Deselect all" : "Select all"
    }

    @Environment(\.themeTokens) private var tokens
    @State private var selection: Set<String>
    private let rows: [ResetUsageRow]
    private let onRequestReset: (Set<String>) -> Void
    private let onCancel: () -> Void

    /// - Parameters:
    ///   - rows: The models, in the order shown.
    ///   - initialSelection: What is ticked when the window opens.
    ///   - onRequestReset: The ticked ids, when "Reset selected…" is pressed.
    ///   - onCancel: Closes the window.
    public init(
        rows: [ResetUsageRow],
        initialSelection: Set<String> = [],
        onRequestReset: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rows = rows
        self._selection = State(initialValue: initialSelection)
        self.onRequestReset = onRequestReset
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            divider
            content
            divider
            actionBar
        }
        .frame(width: tokens.resetUsage.contentWidth)
        .background(tokens.colors.surface.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.controlMetrics.edgeWidth)
    }

    private var content: some View {
        let metrics = tokens.resetUsage
        return VStack(alignment: .leading, spacing: metrics.cardGap) {
            lead
            card
        }
        .padding(.top, metrics.contentPaddingTop)
        .padding(.bottom, metrics.contentPaddingBottom)
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var lead: some View {
        let small = tokens.type.small
        let lineSpacing = tokens.type.bodyLineHeight.map { small.extraLineSpacing(lineHeight: $0) } ?? 0
        return Text("Select models to clear. This will only delete usage data - transcription history is not affected.")
            .font(small.font)
            .foregroundStyle(tokens.colors.secondaryText.color)
            .lineSpacing(lineSpacing)
            .padding(.vertical, lineSpacing / 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The `card`: Select all and its hairline stay put; the models scroll past
    /// `visibleRows`.
    private var card: some View {
        let metrics = tokens.resetUsage
        let shown = min(rows.count, metrics.visibleRows)
        return VStack(spacing: 0) {
            selectAllRow
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        modelRow(row)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: CGFloat(shown) * tokens.sizes.listRow)
        }
        .padding(.horizontal, metrics.cardInset)
        .padding(.bottom, metrics.cardInset)
        .background(tokens.colors.card.color, in: RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous))
    }

    private var selectAllRow: some View {
        let state = Self.selectAllState(selected: selection.count, total: rows.count)
        return Button {
            selection = state == .all ? [] : Set(rows.map(\.id))
        } label: {
            rowContent(
                state: state,
                title: Self.selectAllTitle(selected: selection.count, total: rows.count),
                isCurrent: false
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tokens.colors.edge.color)
                .frame(height: tokens.controlMetrics.edgeWidth)
        }
    }

    private func modelRow(_ row: ResetUsageRow) -> some View {
        Button {
            if selection.contains(row.id) {
                selection.remove(row.id)
            } else {
                selection.insert(row.id)
            }
        } label: {
            rowContent(state: selection.contains(row.id) ? .all : .none, title: row.title, isCurrent: row.isCurrent)
        }
        .buttonStyle(.plain)
    }

    private func rowContent(state: SelectAllState, title: String, isCurrent: Bool) -> some View {
        HStack(spacing: tokens.resetUsage.rowGap) {
            checkbox(state)
            Text(title)
                .font(tokens.type.body.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isCurrent {
                currentPill
            }
        }
        .padding(.horizontal, tokens.spacing.rowPadding)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.sizes.listRow)
        .contentShape(Rectangle())
    }

    /// 14, radius 4. Off: a `mutedEdge` outline on 02. On and mixed: the `checkboxFill`
    /// with its mark in 01.
    private func checkbox(_ state: SelectAllState) -> some View {
        let metrics = tokens.resetUsage
        let box = RoundedRectangle(cornerRadius: tokens.radii.checkbox, style: .continuous)
        return ZStack {
            switch state {
            case .none:
                box.fill(tokens.colors.surface.color)
                box.strokeBorder(tokens.colors.mutedEdge.color, lineWidth: tokens.controlMetrics.edgeWidth)
            case .some:
                box.fill(tokens.colors.checkboxFill.color)
                RoundedRectangle(cornerRadius: metrics.mixedMarkRadius)
                    .fill(tokens.colors.bar.color)
                    .frame(width: metrics.mixedMarkWidth, height: metrics.mixedMarkHeight)
            case .all:
                box.fill(tokens.colors.checkboxFill.color)
                Text("✓")
                    .font(tokens.type.checkMark.font)
                    .foregroundStyle(tokens.colors.bar.color)
            }
        }
        .frame(width: tokens.sizes.checkbox, height: tokens.sizes.checkbox)
    }

    /// The keycap: `sizes.keycap` tall at `radii.control`, 04 under `caption` type in 07.
    private var currentPill: some View {
        Text("Current")
            .font(tokens.type.caption.font)
            .foregroundStyle(tokens.colors.secondaryText.color)
            .padding(.horizontal, tokens.resetUsage.pillPadding)
            .frame(height: tokens.sizes.keycap)
            .background(tokens.colors.raisedControl.color, in: RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous))
    }

    private var actionBar: some View {
        HStack(spacing: tokens.resetUsage.actionGap) {
            Spacer(minLength: 0)
            ThemedPushButton("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            ThemedPushButton("Reset selected…") {
                onRequestReset(selection)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
            .fixedSize()
        }
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.sizes.actionBar)
        .background(tokens.colors.bar.color)
    }
}
