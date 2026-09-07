import ClipboardHistoryStore
import Foundation
import HotkeyEngine

/// Everything the quick-paste popup is configured with, in one value.
///
/// It exists so the four settings travel together: whether the feature runs at all, the
/// key that opens it, how long that key has to be held, and how many entries the panel
/// lists.
public struct QuickPasteConfiguration: Equatable, Sendable {
    /// Default off. Nothing about the feature happens until it is turned on.
    public static let defaultTrigger: TriggerKey = .rightCommand
    /// Matches the long press people already know from phones, and sits clearly above
    /// the 80–300 ms a modifier is held during an ordinary chord.
    public static let defaultHoldDuration: TimeInterval = 0.5
    public static let defaultVisibleEntryCount = 5

    public var isEnabled: Bool
    public var trigger: TriggerKey
    public var holdDuration: TimeInterval
    public var visibleEntryCount: Int

    public init(
        isEnabled: Bool = false,
        trigger: TriggerKey = QuickPasteConfiguration.defaultTrigger,
        holdDuration: TimeInterval = QuickPasteConfiguration.defaultHoldDuration,
        visibleEntryCount: Int = QuickPasteConfiguration.defaultVisibleEntryCount
    ) {
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.holdDuration = holdDuration
        self.visibleEntryCount = visibleEntryCount
    }
}

/// The clipboard watcher, seen from here as nothing but something that can be running or
/// not. `ClipboardMonitor` conforms below; a test can hand in the real one, because
/// starting and stopping its timer needs no clipboard and no permission.
public protocol ClipboardWatcher: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
}

extension ClipboardMonitor: ClipboardWatcher {}

/// The hold-to-reveal gesture, seen from here as something that can be running or not and
/// that takes a configuration.
///
/// It is a protocol because the real implementation owns a `CGEventTap`, an `NSPanel` and
/// `NSEvent.mouseLocation` — none of which exist in `swift test`. What is worth proving
/// is *when* it is asked to run, and that is what this boundary makes provable.
@MainActor
public protocol QuickPasteGestureControlling: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
    func apply(configuration: QuickPasteConfiguration)
}

/// Decides, from the settings and the Accessibility permission, whether the clipboard
/// watcher and the gesture are running — and keeps them that way as either changes.
///
/// This is where "off means off" lives. The feature used to be read once, at launch, and
/// the objects were built only if the hidden flag was on; a real toggle can be flipped at
/// any moment, so the answer has to be recomputed rather than decided once.
///
/// The two conditions are deliberately different:
///
/// - the watcher runs whenever the feature is enabled — polling the pasteboard needs no
///   permission;
/// - the gesture also needs Accessibility, because it is an event tap.
@MainActor
public final class QuickPasteActivation {
    private let watcher: ClipboardWatcher
    private let gesture: QuickPasteGestureControlling

    public private(set) var configuration: QuickPasteConfiguration
    public private(set) var isAccessibilityGranted: Bool

    public init(
        watcher: ClipboardWatcher,
        gesture: QuickPasteGestureControlling,
        configuration: QuickPasteConfiguration = QuickPasteConfiguration(),
        isAccessibilityGranted: Bool = false
    ) {
        self.watcher = watcher
        self.gesture = gesture
        self.configuration = configuration
        self.isAccessibilityGranted = isAccessibilityGranted
        synchronize()
    }

    public func apply(_ configuration: QuickPasteConfiguration) {
        self.configuration = configuration
        synchronize()
    }

    public func setAccessibilityGranted(_ granted: Bool) {
        guard granted != isAccessibilityGranted else { return }
        isAccessibilityGranted = granted
        synchronize()
    }

    /// Called on every change rather than only on the interesting ones. `start` and `stop`
    /// are both idempotent on either side, so the cost of being unconditional is nothing
    /// and the cost of missing a case would be a watcher left polling after the feature
    /// was turned off.
    private func synchronize() {
        gesture.apply(configuration: configuration)

        if configuration.isEnabled {
            watcher.start()
        } else {
            watcher.stop()
        }

        if configuration.isEnabled && isAccessibilityGranted {
            if !gesture.isRunning { gesture.start() }
        } else {
            if gesture.isRunning { gesture.stop() }
        }
    }
}
