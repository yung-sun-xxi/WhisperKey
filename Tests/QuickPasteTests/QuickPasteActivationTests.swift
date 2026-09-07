import XCTest
import ClipboardHistoryStore
import HotkeyEngine
@testable import QuickPaste

/// A gesture that records what was asked of it instead of creating a `CGEventTap`.
private final class FakeGesture: QuickPasteGestureControlling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var applied: [QuickPasteConfiguration] = []

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func apply(configuration: QuickPasteConfiguration) {
        applied.append(configuration)
    }
}

/// A pasteboard that never changes. Enough to build a real `ClipboardMonitor` without
/// touching the system clipboard.
private final class StillPasteboard: ClipboardReading {
    var changeCount = 0
    func read() -> ClipboardContent { ClipboardContent(string: nil, types: []) }
}

private let enabled = QuickPasteConfiguration(
    isEnabled: true,
    trigger: .rightCommand,
    holdDuration: 0.5,
    visibleEntryCount: 5
)

private let disabled = QuickPasteConfiguration(
    isEnabled: false,
    trigger: .rightCommand,
    holdDuration: 0.5,
    visibleEntryCount: 5
)

@MainActor
final class QuickPasteActivationTests: XCTestCase {
    private func makeActivation(
        configuration: QuickPasteConfiguration = disabled,
        accessibilityGranted: Bool = true
    ) -> (QuickPasteActivation, ClipboardMonitor, FakeGesture) {
        let monitor = ClipboardMonitor(pasteboard: StillPasteboard()) { _, _ in }
        let gesture = FakeGesture()
        let activation = QuickPasteActivation(
            watcher: monitor,
            gesture: gesture,
            configuration: configuration,
            isAccessibilityGranted: accessibilityGranted
        )
        return (activation, monitor, gesture)
    }

    func testDisabledLeavesTheWatcherAndTheGestureStopped() {
        let (_, monitor, gesture) = makeActivation(configuration: disabled)

        XCTAssertFalse(monitor.isRunning, "no clipboard poll timer while the feature is off")
        XCTAssertFalse(gesture.isRunning, "no event tap while the feature is off")
        monitor.stop()
    }

    func testEnablingStartsTheWatcherAndTheGesture() {
        let (activation, monitor, gesture) = makeActivation(configuration: disabled)

        activation.apply(enabled)

        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(gesture.isRunning)
        monitor.stop()
    }

    /// The criterion the issue calls "off means off", against the real monitor's own
    /// timer rather than a stand-in for it.
    func testTurningTheToggleOffStopsTheWatcherAndTheGesture() {
        let (activation, monitor, gesture) = makeActivation(configuration: enabled)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(gesture.isRunning)

        activation.apply(disabled)

        XCTAssertFalse(monitor.isRunning, "the clipboard poll timer is invalidated")
        XCTAssertFalse(gesture.isRunning, "the trigger key is no longer watched")
        monitor.stop()
    }

    func testTheWatcherRunsWithoutAccessibilityButTheGestureDoesNot() {
        let (_, monitor, gesture) = makeActivation(
            configuration: enabled,
            accessibilityGranted: false
        )

        XCTAssertTrue(monitor.isRunning, "polling the pasteboard needs no permission")
        XCTAssertFalse(gesture.isRunning, "the event tap does")
        monitor.stop()
    }

    func testRevokingAccessibilityStopsTheGestureAndLeavesTheWatcherRunning() {
        let (activation, monitor, gesture) = makeActivation(configuration: enabled)

        activation.setAccessibilityGranted(false)

        XCTAssertTrue(monitor.isRunning)
        XCTAssertFalse(gesture.isRunning)

        activation.setAccessibilityGranted(true)
        XCTAssertTrue(gesture.isRunning)
        monitor.stop()
    }

    func testTheConfigurationReachesTheGesture() {
        let (activation, monitor, gesture) = makeActivation(configuration: disabled)

        let changed = QuickPasteConfiguration(
            isEnabled: true,
            trigger: .rightShift,
            holdDuration: 0.9,
            visibleEntryCount: 2
        )
        activation.apply(changed)

        XCTAssertEqual(gesture.applied.last, changed)
        XCTAssertEqual(activation.configuration, changed)
        monitor.stop()
    }

    func testApplyingTheSameConfigurationDoesNotRestartTheGesture() {
        let (activation, monitor, gesture) = makeActivation(configuration: enabled)
        let startsAfterInit = gesture.startCount

        activation.apply(enabled)

        XCTAssertEqual(gesture.startCount, startsAfterInit, "already running; nothing to restart")
        monitor.stop()
    }
}

final class QuickPasteConfigurationTests: XCTestCase {
    func testDefaultsMatchTheDocumentedOnes() {
        let configuration = QuickPasteConfiguration()
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.trigger, .rightCommand)
        XCTAssertEqual(configuration.holdDuration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(configuration.visibleEntryCount, 5)
    }
}
