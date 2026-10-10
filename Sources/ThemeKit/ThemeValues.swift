import AppKit
import SwiftUI

/// A colour as a token states it: an sRGB hex value, or one of the system's semantic
/// colours, either at an opacity.
public enum ThemeColor: Hashable, Sendable {
    /// `0xRRGGBB` in sRGB, as the design file writes it.
    case hex(UInt32, opacity: Double = 1)
    /// A system colour, which follows the appearance and the accent colour by itself.
    case system(SystemColor, opacity: Double = 1)

    /// The colour for a SwiftUI view.
    public var color: Color {
        switch self {
        case let .hex(value, opacity):
            return Color(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: opacity
            )
        case let .system(name, opacity):
            let base = name.color
            return opacity == 1 ? base : base.opacity(opacity)
        }
    }
}

/// The system colours Classic draws with today, named as the views name them.
public enum SystemColor: String, Hashable, Sendable {
    /// `Color.clear`: nothing painted, the material or window shows through.
    case clear
    /// `Color.primary`.
    case primary
    /// `Color.secondary`.
    case secondary
    /// `NSColor.labelColor`.
    case label
    /// `NSColor.secondaryLabelColor`.
    case secondaryLabel
    /// `NSColor.windowBackgroundColor`.
    case windowBackground
    /// `NSColor.controlBackgroundColor`.
    case controlBackground
    /// `Color.accentColor`.
    case accent
    /// `Color.green`.
    case green
    /// `Color.red`.
    case red
    /// `Color.white`.
    case white
    /// `Color.black`.
    case black

    public var color: Color {
        switch self {
        case .clear: return .clear
        case .primary: return .primary
        case .secondary: return .secondary
        case .label: return Color(nsColor: .labelColor)
        case .secondaryLabel: return Color(nsColor: .secondaryLabelColor)
        case .windowBackground: return Color(nsColor: .windowBackgroundColor)
        case .controlBackground: return Color(nsColor: .controlBackgroundColor)
        case .accent: return .accentColor
        case .green: return .green
        case .red: return .red
        case .white: return .white
        case .black: return .black
        }
    }
}

/// A system (SF) font as a token states it: size, weight, tracking, and whether the
/// digits are tabular.
public struct ThemeFont: Hashable, Sendable {
    public var size: CGFloat
    public var weight: Weight
    /// Letter spacing in em; 0.06 for the caps headers.
    public var trackingEm: CGFloat
    /// Tabular (monospaced) digits, for figures that change in place.
    public var tabularDigits: Bool

    public init(size: CGFloat, weight: Weight, trackingEm: CGFloat = 0, tabularDigits: Bool = false) {
        self.size = size
        self.weight = weight
        self.trackingEm = trackingEm
        self.tabularDigits = tabularDigits
    }

    /// The numeric weights the design file writes (400, 500, 600, 700).
    public enum Weight: Int, Hashable, Sendable {
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700

        public var swiftUI: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    /// The font for a SwiftUI view. Tracking is not part of a `Font`; apply
    /// `tracking` with `.tracking(_:)`.
    public var font: Font {
        let font = Font.system(size: size, weight: weight.swiftUI)
        return tabularDigits ? font.monospacedDigit() : font
    }

    /// Letter spacing in points, for `.tracking(_:)`.
    public var tracking: CGFloat { size * trackingEm }
}
