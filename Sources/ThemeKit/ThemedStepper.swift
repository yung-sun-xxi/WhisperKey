import AppKit
import SwiftUI

/// Which way a stepper moves its value.
public enum StepDirection: Sendable {
    case up
    case down
}

/// The stepper's arithmetic, apart from any view: one step, kept inside the range.
public enum SteppedValue {
    /// `value` moved one `step` in `direction`, clamped to `range`. A value already outside
    /// the range comes back to its nearer end.
    public static func next(from value: Int, direction: StepDirection, step: Int, range: ClosedRange<Int>) -> Int {
        let moved = direction == .up ? value + step : value - step
        return min(max(moved, range.lowerBound), range.upperBound)
    }

    /// Whether a step in `direction` can change `value`.
    public static func canStep(from value: Int, direction: StepDirection, range: ClosedRange<Int>) -> Bool {
        switch direction {
        case .up: return value < range.upperBound
        case .down: return value > range.lowerBound
        }
    }
}

/// Midnight's stepper: a 22×26 box with two triangles, drawn from the tokens. It repeats
/// while held, as the system stepper does, and speaks to VoiceOver as an incrementor.
struct DrawnStepper: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let tokens: ThemeTokens
    let accessibilityLabel: String

    func makeNSView(context: Context) -> DrawnStepperControl {
        let control = DrawnStepperControl()
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        update(control, context: context)
        return control
    }

    func updateNSView(_ control: DrawnStepperControl, context: Context) {
        update(control, context: context)
    }

    private func update(_ control: DrawnStepperControl, context: Context) {
        control.tokens = tokens
        control.range = range
        control.step = step
        control.currentValue = { value }
        control.setValue = { value = $0 }
        control.isEnabled = context.environment.isEnabled
        control.setAccessibilityLabel(accessibilityLabel)
        control.needsDisplay = true
    }
}

final class DrawnStepperControl: NSControl {
    /// How long the button must be held before it repeats, and how often it then steps:
    /// the system stepper's rhythm.
    private static let repeatDelay: TimeInterval = 0.5
    private static let repeatInterval: TimeInterval = 0.08

    var tokens = ThemeTokens.midnight {
        didSet { invalidateIntrinsicContentSize() }
    }
    var range: ClosedRange<Int> = 0...0
    var step = 1
    var currentValue: () -> Int = { 0 }
    var setValue: (Int) -> Void = { _ in }

    private var repeatTimer: Timer?
    private var pressed: StepDirection?

    override var intrinsicContentSize: NSSize {
        tokens.controlMetrics.stepper
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled && isEnabled
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = tokens.controlMetrics
        let colors = tokens.colors
        let edge = metrics.edgeWidth
        let box = bounds.insetBy(dx: edge / 2, dy: edge / 2)
        let radius = tokens.radii.control
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        if isEnabled {
            (pressed == nil ? colors.card : colors.raisedControl).nsColor.setFill()
            path.fill()
        }
        colors.edge.nsColor.setStroke()
        path.lineWidth = edge
        path.stroke()

        let arrow = metrics.stepperArrow
        let gap = metrics.stepperArrowGap
        let centreX = bounds.midX
        let top = bounds.midY - gap / 2 - arrow
        let bottom = bounds.midY + gap / 2
        colors.secondaryText.nsColor.setFill()
        triangle(apexAt: NSPoint(x: centreX, y: top), baseY: top + arrow, halfBase: arrow).fill()
        triangle(apexAt: NSPoint(x: centreX, y: bottom + arrow), baseY: bottom, halfBase: arrow).fill()
    }

    private func triangle(apexAt apex: NSPoint, baseY: CGFloat, halfBase: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: apex)
        path.line(to: NSPoint(x: apex.x + halfBase, y: baseY))
        path.line(to: NSPoint(x: apex.x - halfBase, y: baseY))
        path.close()
        return path
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let direction: StepDirection = point.y < bounds.midY ? .up : .down
        pressed = direction
        stepOnce(direction)
        needsDisplay = true

        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeating(direction) }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    override func mouseUp(with event: NSEvent) {
        stopRepeating()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopRepeating() }
    }

    private func startRepeating(_ direction: StepDirection) {
        guard pressed == direction else { return }
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepOnce(direction) }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        pressed = nil
        needsDisplay = true
    }

    private func stepOnce(_ direction: StepDirection) {
        let value = currentValue()
        guard SteppedValue.canStep(from: value, direction: direction, range: range) else { return }
        setValue(SteppedValue.next(from: value, direction: direction, step: step, range: range))
    }

    // MARK: Keyboard and accessibility

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?: stepOnce(.up)
        case .downArrow?: stepOnce(.down)
        default: super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .incrementor }
    override func accessibilityValue() -> Any? { currentValue() }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformIncrement() -> Bool {
        stepOnce(.up)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        stepOnce(.down)
        return true
    }
}
