import SwiftUI

/// The popover's period picker (Today · 7d · 30d · All, #161): a full-width `card`
/// track `sizes.periodTrack` tall at `radii.card`, padded `trackPadding` with
/// `segmentGap` between segments `sizes.periodSegment` tall. Labels in `caption` and
/// `navigationText`; the active segment is `brand` at `radii.segment` with its label in
/// `segmentLabelOnBrand` and `onBrand` (#105 rule 1).
public struct ThemedPeriodPicker<Value: Hashable>: View {
    @Environment(\.themeTokens) private var tokens
    private let label: String
    @Binding private var selection: Value
    private let options: [Value]
    private let title: (Value) -> String
    private let help: (Value) -> String

    public init(
        _ label: String,
        selection: Binding<Value>,
        options: [Value],
        title: @escaping (Value) -> String,
        help: @escaping (Value) -> String
    ) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
        self.help = help
    }

    public var body: some View {
        let metrics = tokens.controlMetrics
        let colors = tokens.colors
        HStack(spacing: metrics.segmentGap) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font((isSelected ? tokens.type.segmentLabelOnBrand : tokens.type.caption).font)
                        .foregroundStyle((isSelected ? colors.onBrand : colors.navigationText).color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: tokens.sizes.periodSegment)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: tokens.radii.segment, style: .continuous)
                                    .fill(colors.brand.color)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(option))
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(metrics.trackPadding)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.sizes.periodTrack)
        .background(
            colors.card.color,
            in: RoundedRectangle(cornerRadius: tokens.radii.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
