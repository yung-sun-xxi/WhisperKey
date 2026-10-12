import AppKit
import Combine
import SwiftUI

// The shell the floating panels share (#105 rule 4): the menu bar popover (#161), the quick
// paste popup (#166) and the toast (#167). Two halves: `ThemedPanelShell` draws the fill,
// the rounded shape and the edge in SwiftUI, around the panel's content;
// `ThemedPanelChromeView` is the window's content view, holding the blur behind the window
// and the hosting view, and keeps the window's appearance on the theme's.

/// Which floating panel a shell is for; each has its own width in `panels`.
public enum PanelKind: Sendable {
    case popover
    case quickPaste
    case toast

    public func shell(in tokens: ThemeTokens) -> PanelShell {
        switch self {
        case .popover: return tokens.panels.popover
        case .quickPaste: return tokens.panels.quickPaste
        case .toast: return tokens.panels.toast
        }
    }
}

/// A floating panel's look around its content: `shell.width` wide, the shell's fill (02
/// at 95% in Midnight) clipped to `shell.radius`, and its `edgeWidth` edge drawn inside
/// the shape. The blur under the fill is the window's (`ThemedPanelChromeView`).
public struct ThemedPanelShell<Content: View>: View {
    @Environment(\.themeTokens) private var tokens
    private let kind: PanelKind
    private let content: Content

    public init(_ kind: PanelKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    public var body: some View {
        let shell = kind.shell(in: tokens)
        let shape = RoundedRectangle(cornerRadius: shell.radius, style: .continuous)
        content
            .frame(width: shell.width)
            .background(fill(shell).color)
            .clipShape(shape)
            .overlay {
                if let edge = shell.edge {
                    shape
                        .strokeBorder(edge.color, lineWidth: shell.edgeWidth)
                        .allowsHitTesting(false)
                }
            }
    }

    /// A material shell has no fill of its own: the window's blur is the whole of it.
    private func fill(_ shell: PanelShell) -> ThemeColor {
        switch shell.background {
        case .material: return .system(.clear)
        case let .fill(color, _): return color
        }
    }
}

/// The content view of a floating panel's window: a blur of what lies behind the window,
/// rounded to the shell's radius, with the panel's hosting view on top.
///
/// `NSVisualEffectView` takes no blur radius, so `.fill(color, blur:)` maps to a
/// behind-window material with the fill drawn over it by `ThemedPanelShell`. The view
/// follows `ThemeTokensSource.shared` live: material, radius and the window's appearance
/// (dark for Midnight, so its context menus and tooltips match).
@MainActor
public final class ThemedPanelChromeView: NSView {
    private let kind: PanelKind
    private let source: ThemeTokensSource
    private let effectView = NSVisualEffectView()
    private var subscription: AnyCancellable?

    /// Follows `ThemeTokensSource.shared`.
    public convenience init(kind: PanelKind, contentView: NSView) {
        self.init(kind: kind, contentView: contentView, source: .shared)
    }

    public init(kind: PanelKind, contentView: NSView, source: ThemeTokensSource) {
        self.kind = kind
        self.source = source
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = ThemeColor.system(.clear).nsColor.cgColor

        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        apply(source.tokens)
        subscription = source.$tokens
            .removeDuplicates()
            .sink { [weak self] tokens in
                MainActor.assumeIsolated { self?.apply(tokens) }
            }
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var isOpaque: Bool { false }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply(source.tokens)
    }

    /// The window a floating panel lives in: borderless and see-through, so the shell's
    /// rounded shape is its outline, with the window server's shadow (`ThemeShadow.system`;
    /// the panels keep it, see `PanelShell.shadow`).
    public static func configure(_ window: NSWindow) {
        window.backgroundColor = ThemeColor.system(.clear).nsColor
        window.isOpaque = false
        window.hasShadow = true
    }

    private func apply(_ tokens: ThemeTokens) {
        let shell = kind.shell(in: tokens)
        switch shell.background {
        case let .material(material):
            effectView.material = material.nsMaterial
        case .fill:
            effectView.material = .popover
        }
        effectView.layer?.cornerRadius = shell.radius
        if let window {
            window.appearance = tokens.windowAppearance.nsAppearance
            // The shadow follows the window's opaque pixels, which the radius shapes.
            window.invalidateShadow()
        }
    }
}

extension PanelMaterial {
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .popover: return .popover
        case .hudWindow: return .hudWindow
        }
    }
}
