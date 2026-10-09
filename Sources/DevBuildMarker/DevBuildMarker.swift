// Compiled only under DEBUG: the Release build carries no trace of the marker (#149).
#if DEBUG
import AppKit

/// Tells the dev app (WhisperKey Dev, Debug configuration) apart from the release app
/// at a glance: a D beside the menu bar icon and in the popover header.
public enum DevBuildMarker {
    /// The letter shown in the menu bar and the popover badge.
    public static let letter = "D"

    /// Space between the icon and the letter, in points.
    static let gap: CGFloat = 2

    /// Bold, sized to read next to an icon in an 18 pt menu bar slot.
    static let font = NSFont.systemFont(ofSize: 12, weight: .bold)

    /// The base menu bar icon with the letter drawn to its trailing side, as one
    /// template image. The letter is part of the image on purpose: the status button
    /// must hold no text field (macOS 27 snapshot loop), and its title is the timer.
    public static func markedMenuBarImage(_ base: NSImage) -> NSImage {
        let text = NSAttributedString(
            string: letter,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        let textSize = text.size()
        let size = NSSize(
            width: (base.size.width + gap + textSize.width).rounded(.up),
            height: max(base.size.height, textSize.height).rounded(.up)
        )

        let image = NSImage(size: size, flipped: false) { rect in
            let baseOrigin = NSPoint(x: 0, y: ((rect.height - base.size.height) / 2).rounded())
            base.draw(
                in: NSRect(origin: baseOrigin, size: base.size),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            // Centre the capital on the icon's midline rather than the line box,
            // which carries descender space a capital D never uses.
            let capCenterFromBaseline = font.capHeight / 2
            let baselineY = rect.height / 2 - capCenterFromBaseline
            let textOrigin = NSPoint(
                x: base.size.width + gap,
                y: (baselineY + font.descender).rounded()
            )
            text.draw(at: textOrigin)
            return true
        }
        image.isTemplate = true
        return image
    }
}
#endif
