import AppKit
import SwiftUI

/// Midnight's pop-up: a system `NSPopUpButton`, so its menu, keyboard handling and
/// VoiceOver stay the system's, with a cell that draws the closed button from the tokens:
/// a `card` box with an `edge` outline, the title in `body`, up and down chevrons in
/// `secondaryText`. Disabled, it is the sheet's disabled control: no fill, 05 edge,
/// 07 label.
struct DrawnPopUpButton: NSViewRepresentable {
    let titles: [String]
    @Binding var selectedIndex: Int
    let tokens: ThemeTokens

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedIndex: $selectedIndex)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.cell = DrawnPopUpButtonCell(textCell: "", pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        update(button, context: context)
    }

    private func update(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selectedIndex = $selectedIndex
        (button.cell as? DrawnPopUpButtonCell)?.tokens = tokens
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if titles.indices.contains(selectedIndex), button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.isEnabled = context.environment.isEnabled
        button.invalidateIntrinsicContentSize()
        button.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var selectedIndex: Binding<Int>

        init(selectedIndex: Binding<Int>) {
            self.selectedIndex = selectedIndex
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            selectedIndex.wrappedValue = sender.indexOfSelectedItem
        }
    }
}

final class DrawnPopUpButtonCell: NSPopUpButtonCell {
    var tokens = ThemeTokens.midnight

    private var chevronWidth: CGFloat { tokens.controlMetrics.popUpChevron * 2 }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: tokens.type.body.nsFont,
            .foregroundColor: (isEnabled ? tokens.colors.primaryText : tokens.colors.secondaryText).nsColor,
        ]
    }

    override var cellSize: NSSize {
        let metrics = tokens.controlMetrics
        let titleWidth = (titleOfSelectedItem ?? "").size(withAttributes: titleAttributes).width
        let width = metrics.horizontalPadding + ceil(titleWidth) + metrics.popUpTitleGap + chevronWidth + metrics.horizontalPadding
        return NSSize(width: max(metrics.popUpMinWidth, width), height: tokens.sizes.control)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let metrics = tokens.controlMetrics
        let colors = tokens.colors
        let edge = metrics.edgeWidth
        let radius = tokens.radii.control
        let box = cellFrame.insetBy(dx: edge / 2, dy: edge / 2)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        if isEnabled {
            (isHighlighted ? colors.raisedControl : colors.card).nsColor.setFill()
            path.fill()
        }
        colors.edge.nsColor.setStroke()
        path.lineWidth = edge
        path.stroke()

        // The chevrons, centred on the box's height at its trailing padding.
        let chevron = metrics.popUpChevron
        let chevronX = cellFrame.maxX - metrics.horizontalPadding - chevronWidth
        let flipped = controlView.isFlipped
        let midY = cellFrame.midY
        let upperBase = midY - metrics.popUpChevronGap / 2
        let lowerBase = midY + metrics.popUpChevronGap / 2
        colors.secondaryText.nsColor.setFill()
        // In a flipped view smaller y is higher on screen.
        let upApex = flipped ? upperBase - chevron : lowerBase + chevron
        let upBase = flipped ? upperBase : lowerBase
        let downApex = flipped ? lowerBase + chevron : upperBase - chevron
        let downBase = flipped ? lowerBase : upperBase
        triangle(left: chevronX, width: chevronWidth, apexY: upApex, baseY: upBase).fill()
        triangle(left: chevronX, width: chevronWidth, apexY: downApex, baseY: downBase).fill()

        // The title, vertically centred, clipped before the chevrons.
        let title = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: titleAttributes)
        let titleSize = title.size()
        let titleRect = NSRect(
            x: cellFrame.minX + metrics.horizontalPadding,
            y: cellFrame.midY - titleSize.height / 2,
            width: max(0, chevronX - metrics.popUpTitleGap - cellFrame.minX - metrics.horizontalPadding),
            height: titleSize.height
        )
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func triangle(left: CGFloat, width: CGFloat, apexY: CGFloat, baseY: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left + width / 2, y: apexY))
        path.line(to: NSPoint(x: left + width, y: baseY))
        path.line(to: NSPoint(x: left, y: baseY))
        path.close()
        return path
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        let radius = tokens.radii.control
        NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }
}
