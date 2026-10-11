import SwiftUI

/// Tab selection by index, the way the tab well and the `NSTabViewController` under it
/// share it.
public enum TabWellSelection {
    /// The index of the tab with `identifier`, or nil when there is none.
    public static func index(of identifier: String, in identifiers: [String]) -> Int? {
        identifiers.firstIndex(of: identifier)
    }

    /// `index` kept inside `count` tabs; 0 when there are none.
    public static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}

/// The Settings window's tabs (#162): a band on `bar` holding a `card` track of equal
/// segments, the active one filled with the brand. Both themes draw it; Classic in its own
/// tokens, as the popover's period picker. A line in `divider` runs above the band and
/// another below it.
public struct ThemedTabWell: View {
    @Environment(\.themeTokens) private var tokens
    private let titles: [String]
    @Binding private var selection: Int

    public init(titles: [String], selection: Binding<Int>) {
        self.titles = titles
        _selection = selection
    }

    public var body: some View {
        let window = tokens.settingsWindow
        VStack(spacing: 0) {
            ThemedDivider()
            HStack(spacing: window.tabSegmentGap) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    segment(title, isSelected: index == selection) {
                        selection = index
                    }
                }
            }
            .padding(window.tabTrackPadding)
            .background(tokens.colors.card.color, in: RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous))
            .padding(.vertical, window.tabWellPadding)
            .padding(.horizontal, tokens.spacing.windowTextEdge)
            .background(tokens.colors.bar.color)
            ThemedDivider()
        }
        .accessibilityElement(children: .contain)
    }

    private func segment(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let font = isSelected ? tokens.type.labelOnBrand : tokens.type.small
        return Button(action: action) {
            Text(title)
                .font(font.font)
                .foregroundStyle((isSelected ? tokens.colors.onBrand : tokens.colors.navigationText).color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: tokens.settingsWindow.tabSegmentHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: tokens.radii.segment, style: .continuous)
                            .fill(tokens.colors.brand.color)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A 1pt line in `divider`, full width.
public struct ThemedDivider: View {
    @Environment(\.themeTokens) private var tokens

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.settingsWindow.dividerWidth)
    }
}
