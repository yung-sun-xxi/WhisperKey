import AppKit

extension NSWindow {
    /// Puts the window on screen from fully transparent and animates it to opaque.
    ///
    /// `orderFrontRegardless` rather than `orderFront`, because WhisperKey is an accessory
    /// app that never activates: an ordinary `orderFront` from a background application is
    /// ignored.
    ///
    /// The window must be positioned before this is called — it appears at whatever origin
    /// it already has.
    func fadeInOrderingFront(duration: TimeInterval) {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
        }
    }
}
