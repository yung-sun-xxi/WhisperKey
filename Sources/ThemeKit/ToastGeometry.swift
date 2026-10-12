import CoreGraphics

public extension ThemeTokens {
    /// The toast's window: the card (`panels.toast.width`) with the clear `toast.margin`
    /// on both sides, for the close disc that overhangs the card's corner.
    var toastWindowWidth: CGFloat {
        panels.toast.width + toast.margin * 2
    }

    /// From the right edge of the screen's visible area to the window, so that the card
    /// inside it lands `toast.screenEdgeInset` from that edge.
    var toastWindowRightInset: CGFloat {
        max(toast.screenEdgeInset - toast.margin, 0)
    }

    /// From the bottom of the menu bar to the window, so that the card inside it lands
    /// `toast.menuBarGap` under the menu bar.
    var toastWindowTopInset: CGFloat {
        max(toast.menuBarGap - toast.margin, 0)
    }
}
