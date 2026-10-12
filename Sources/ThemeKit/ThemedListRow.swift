import SwiftUI

// The list row the floating panels and the history windows share (#161; the quick paste
// popup #166 and the full history window #164 reuse it), with the failed-row hatch and
// the dashed Retry button that go with it.

/// One row of a list: `sizes.listRow` tall, `spacing.rowPadding` inside, `radii.row`,
/// the `selectedRow` fill under the pointer. A failed row lies on `failureFill` under
/// the `failureHatch` stripes instead (#105 rule 1: failure is a state, not a brand
/// moment). The caller insets the list `spacing.rowInset` from the shell and styles the
/// row's text.
public struct ThemedListRow<Content: View>: View {
    public enum Style: Sendable {
        case normal
        case failed
    }

    @Environment(\.themeTokens) private var tokens
    @State private var isHovered = false
    private let style: Style
    private let content: Content

    public init(style: Style = .normal, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: tokens.radii.row, style: .continuous)
        content
            .padding(.horizontal, tokens.spacing.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: tokens.sizes.listRow)
            .background {
                switch style {
                case .failed:
                    shape
                        .fill(tokens.colors.failureFill.color)
                        .overlay(ThemedFailureHatch().clipShape(shape))
                case .normal:
                    shape.fill((isHovered ? tokens.colors.selectedRow : ThemeColor.system(.clear)).color)
                }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }
}

/// The failed row's stripes: `failureHatchStripe` wide every `failureHatchPeriod`,
/// at 135° as the design's `repeating-linear-gradient(135deg, …)` lays them, in
/// `failureHatch`.
public struct ThemedFailureHatch: View {
    @Environment(\.themeTokens) private var tokens

    public init() {}

    public var body: some View {
        let metrics = tokens.controlMetrics
        let color = tokens.colors.failureHatch.color
        Canvas { context, size in
            // A 135° gradient runs toward the bottom right; its stripes are the lines
            // x + y = c, and `period` along the gradient is `period * √2` along x.
            let step = metrics.failureHatchPeriod * 2.squareRoot()
            let firstCentre = metrics.failureHatchStripe / 2 * 2.squareRoot()
            var path = Path()
            var c = firstCentre
            while c - size.height <= size.width + step {
                path.move(to: CGPoint(x: c, y: 0))
                path.addLine(to: CGPoint(x: c - size.height, y: size.height))
                c += step
            }
            context.stroke(path, with: .color(color), lineWidth: metrics.failureHatchStripe)
        }
        .allowsHitTesting(false)
    }
}

/// The button a failed row carries ("Retry"): `type.caption` in `primaryText`,
/// `sizes.keycap` tall, `badgePadding` inside a dashed `mutedEdge` at `radii.control`.
/// Grey like its row (#105 rule 1).
public struct ThemedFailureButton: View {
    @Environment(\.themeTokens) private var tokens
    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        let metrics = tokens.controlMetrics
        let box = RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(tokens.type.caption.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .lineLimit(1)
                .padding(.horizontal, metrics.badgePadding)
                .frame(height: tokens.sizes.keycap)
                .overlay(
                    box.strokeBorder(
                        tokens.colors.mutedEdge.color,
                        style: StrokeStyle(lineWidth: metrics.edgeWidth, dash: metrics.failureDash)
                    )
                )
                .contentShape(box)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
