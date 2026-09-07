import AppKit
import SwiftUI

/// An `NSVisualEffectView` behind SwiftUI content, for the app's borderless panels.
///
/// It exists because SwiftUI's own `Material` is not a substitute here. A `Material` fill
/// blends with what is *inside* the window; in a borderless panel whose `backgroundColor`
/// is `.clear` there is nothing inside the window behind it, so the material paints its
/// flat base colour and the panel reads as an opaque slab over whatever it covers. An
/// `NSVisualEffectView` with `blendingMode = .behindWindow` blurs the windows underneath
/// the panel instead, which is what a floating macOS panel looks like.
///
/// Appearance is not part of the difference: both follow `effectiveAppearance`, and both
/// are dark on a dark system. `ToastView` has used this since the toast was written;
/// `QuickPasteView` uses it now too, which is why it lives in its own file rather than
/// private to one of them.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
