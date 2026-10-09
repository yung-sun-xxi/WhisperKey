import AppKit
import Combine
import os
import SwiftUI
#if DEBUG
import DevBuildMarker
#endif

enum MenuBarLayout {
    static let popoverWidth: CGFloat = 306
}

@MainActor
final class MenuBarController: NSObject {
    private static let log = Logger(subsystem: "WhisperKey", category: "MenuBarController")
    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55
    /// The icon is fitted into a square of this side, as the old 18x18 image view did.
    private static let statusIconMaxSide: CGFloat = 18
    private static let processingIndicatorSide: CGFloat = 14
    private static let timerFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let emptyTitle = NSAttributedString(string: "")
    /// An invisible title as wide as the spinner. With `.imageTrailing` it makes the
    /// button reserve a slot left of the icon, and the spinner is placed into that slot.
    private static let processingIndicatorSlotTitle: NSAttributedString = {
        let side = processingIndicatorSide
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: side, height: 1), flipped: false) { _ in true }
        attachment.bounds = NSRect(x: 0, y: 0, width: side, height: 1)
        return NSAttributedString(attachment: attachment)
    }()

    let coordinator: AppCoordinator

    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hostingView: TransparentHostingView
    private let processingIndicator = MouseTransparentProgressIndicator(frame: .zero)
    /// The title last handed to the button. `updateStatusItem()` runs on every
    /// coordinator change, and every real assignment to the status button costs an
    /// out-of-process menu bar snapshot, so only actual changes are applied.
    private var appliedStatusTitle = MenuBarController.emptyTitle
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: Timer?
    private var blinkOn = true

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hostingView = TransparentHostingView(rootView: AnyView(EmptyView()))
        panel = MenuBarPanel()

        super.init()

        configureStatusItem()
        configurePanel()
        observeCoordinator()
        observeAppActivation()

        Self.log.info("initialized pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) bundleID=\(Bundle.main.bundleIdentifier ?? "nil", privacy: .public) bundlePath=\(Bundle.main.bundlePath, privacy: .public) executablePath=\(Bundle.main.executablePath ?? "nil", privacy: .public)")

        coordinator.openMenuBarPopoverHandler = { [weak self] in
            self?.showPopover()
        }
        coordinator.closeMenuBarPopoverHandler = { [weak self] in
            self?.closePopover()
        }
        prewarmSettingsWindow()
        coordinator.scheduleWelcomePresentationAfterLaunch()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in
            TransientWindowStack.shared.unregister(id: "menuBarPopover")
        }
        blinkTimer?.invalidate()
        processingIndicator.stopAnimation(nil)
    }

    func togglePopover() {
        Self.log.info("togglePopover visibleBefore=\(self.panel.isVisible, privacy: .public) isKeyBefore=\(self.panel.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        if panel.isVisible {
            TransientWindowStack.shared.dismissAll()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        Self.log.info("showPopover begin appActive=\(NSApp.isActive, privacy: .public) visibleBefore=\(self.panel.isVisible, privacy: .public) isKeyBefore=\(self.panel.isKeyWindow, privacy: .public) buttonWindowExists=\((self.statusItem.button?.window != nil), privacy: .public) currentFrame=\(String(describing: self.panel.frame), privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        updatePanelSize()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        statusItem.button?.state = .on
        TransientWindowStack.shared.register(
            id: "menuBarPopover",
            layer: .root,
            window: panel,
            containsScreenPoint: { [weak self] point in
                self?.statusItemScreenFrame()?.contains(point) == true
            }
        ) { [weak self] in
            self?.closePopover(reason: "transient-stack")
        }
        Self.log.info("showPopover ordered appActive=\(NSApp.isActive, privacy: .public) visibleAfter=\(self.panel.isVisible, privacy: .public) isKeyAfter=\(self.panel.isKeyWindow, privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
            Self.log.info("showPopover deferred makeKey visible=\(self.panel.isVisible, privacy: .public) isKey=\(self.panel.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public)")
        }
    }

    func closePopover() {
        closePopover(reason: "external")
    }

    private func closePopover(reason: String, closeRelatedWindows: Bool = false) {
        Self.log.info("closePopover reason=\(reason, privacy: .public) closeRelatedWindows=\(closeRelatedWindows, privacy: .public) visibleBefore=\(self.panel.isVisible, privacy: .public) isKeyBefore=\(self.panel.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public)")
        TransientWindowStack.shared.unregister(id: "menuBarPopover")
        panel.orderOut(nil)
        if closeRelatedWindows {
            SettingsWindowController.hide()
            HistoryFullWindowController.hide()
            UsageBreakdownWindowController.hide()
        }
        statusItem.button?.state = .off
        Self.log.info("closePopover complete reason=\(reason, privacy: .public) visibleAfter=\(self.panel.isVisible, privacy: .public) isKeyAfter=\(self.panel.isKeyWindow, privacy: .public)")
    }

    private func prewarmSettingsWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            SettingsWindowController.prepare(coordinator: self.coordinator)
        }
    }

    // The status button holds no text field and no auto layout of its own. On macOS 27
    // the menu bar draws the item out of process from snapshots, and before each one
    // AppKit sets the appearance on the button's view tree. An NSTextField answers that
    // by invalidating its intrinsic size, which schedules the next snapshot, and the
    // item loops forever at 50-90% CPU even while the field is hidden. The timer is
    // therefore the button's native title and the icon its native image.
    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = Self.makeMenuBarImage()
        button.imagePosition = .imageTrailing
        button.attributedTitle = appliedStatusTitle
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.toolTip = "WhisperKey"
        configureProcessingIndicator(in: button)

        updateStatusItem()
    }

    private func configureProcessingIndicator(in button: NSStatusBarButton) {
        processingIndicator.style = .spinning
        processingIndicator.controlSize = .small
        processingIndicator.isIndeterminate = true
        processingIndicator.isDisplayedWhenStopped = false
        processingIndicator.isHidden = true
        processingIndicator.autoresizingMask = [.minYMargin, .maxYMargin]
        button.addSubview(processingIndicator)
    }

    private func configurePanel() {
        hostingView.rootView = AnyView(
            PopoverContent().environmentObject(coordinator)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = PopoverChromeView(contentView: hostingView)
    }

    private func updatePanelSize() {
        let fittingSize = hostingView.fittingSize
        let panelSize = NSSize(
            width: MenuBarLayout.popoverWidth,
            height: fittingSize.height
        )
        panel.setContentSize(panelSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        Self.log.info("updatePanelSize fittingSize=\(String(describing: fittingSize), privacy: .public) panelSize=\(String(describing: panelSize), privacy: .public)")
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            Self.log.error("positionPanel failed missing status button window buttonExists=\((self.statusItem.button != nil), privacy: .public)")
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let iconFrameInScreen = statusIconScreenFrame() ?? buttonFrameInScreen
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = panel.frame.size

        let padding: CGFloat = 6
        let rightAnchoredX = iconFrameInScreen.maxX - panelSize.width
        let preferredX = iconFrameInScreen.minX
        let x = if preferredX + panelSize.width <= visibleFrame.maxX - padding {
            max(preferredX, visibleFrame.minX + padding)
        } else {
            max(rightAnchoredX, visibleFrame.minX + padding)
        }
        let y = buttonFrameInScreen.minY - panelSize.height

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        Self.log.info("positionPanel buttonFrame=\(String(describing: buttonFrameInScreen), privacy: .public) iconFrame=\(String(describing: iconFrameInScreen), privacy: .public) visibleFrame=\(String(describing: visibleFrame), privacy: .public) panelSize=\(String(describing: panelSize), privacy: .public) origin=\(String(describing: NSPoint(x: x, y: y)), privacy: .public)")
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem.button,
              let buttonWindow = button.window
        else { return nil }

        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Where the button's cell draws the icon, in screen coordinates.
    private func statusIconScreenFrame() -> NSRect? {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let cell = button.cell as? NSButtonCell
        else { return nil }

        let iconRect = cell.imageRect(forBounds: button.bounds)
        return buttonWindow.convertToScreen(button.convert(iconRect, to: nil))
    }

    private func observeCoordinator() {
        coordinator.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let title: NSAttributedString
        let toolTip: String
        let showsProcessingIndicator: Bool

        switch coordinator.state {
        case .starting:
            title = Self.emptyTitle
            toolTip = "Starting microphone..."
            showsProcessingIndicator = false
            stopBlinkTimer(resetBlink: true)
        case .recording:
            title = NSAttributedString(
                string: coordinator.recordingTimerText,
                attributes: [.font: Self.timerFont, .foregroundColor: timerColor]
            )
            toolTip = "Recording \(coordinator.recordingTimerText)"
            showsProcessingIndicator = false
            updateBlinkTimer()
        case .transcribing:
            stopBlinkTimer(resetBlink: true)
            title = Self.processingIndicatorSlotTitle
            toolTip = "Transcribing..."
            showsProcessingIndicator = true
        case .idle, .error, .microphoneDenied, .accessibilityDenied:
            title = Self.emptyTitle
            toolTip = "WhisperKey"
            showsProcessingIndicator = false
            stopBlinkTimer(resetBlink: true)
        }

        // Icon only: a square item, as before, when the icon fits the square. An icon
        // wider than the bar is tall (the dev build's icon with its D) takes its natural
        // width instead of being clipped or scaled down. With a title the item takes the
        // button's natural width, title (or the spinner's slot) left of the icon.
        let iconFitsSquare = (button.image?.size.width ?? 0) <= NSStatusBar.system.thickness
        let length = title.length == 0 && iconFitsSquare
            ? NSStatusItem.squareLength
            : NSStatusItem.variableLength
        if statusItem.length != length {
            statusItem.length = length
        }
        if !appliedStatusTitle.isEqual(to: title) {
            button.attributedTitle = title
            appliedStatusTitle = title
        }
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }
        updateProcessingIndicator(visible: showsProcessingIndicator, in: button)
    }

    private static func makeMenuBarImage() -> NSImage? {
        guard let asset = NSImage(named: "MenuBarIcon"),
              let image = asset.copy() as? NSImage
        else { return nil }

        // The asset is 22x18 pt; the old image view showed it scaled down into an
        // 18x18 box. Sizing a copy keeps that look without touching the shared asset.
        let longestSide = max(image.size.width, image.size.height)
        if longestSide > statusIconMaxSide {
            let scale = statusIconMaxSide / longestSide
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        image.isTemplate = true
        #if DEBUG
        // The dev app carries a D beside the icon, drawn into the image itself (#149).
        return DevBuildMarker.markedMenuBarImage(image)
        #else
        return image
        #endif
    }

    /// Puts the spinner into the slot the button reserved for the invisible title,
    /// which `.imageTrailing` lays out left of the icon.
    private func updateProcessingIndicator(visible: Bool, in button: NSStatusBarButton) {
        guard visible else {
            if !processingIndicator.isHidden {
                processingIndicator.stopAnimation(nil)
                processingIndicator.isHidden = true
            }
            return
        }

        if let cell = button.cell as? NSButtonCell {
            let slot = cell.titleRect(forBounds: button.bounds)
            let side = Self.processingIndicatorSide
            let frame = NSRect(
                x: slot.minX,
                y: ((button.bounds.height - side) / 2).rounded(),
                width: side,
                height: side
            )
            if processingIndicator.frame != frame {
                processingIndicator.frame = frame
            }
        }
        if processingIndicator.isHidden {
            processingIndicator.isHidden = false
            processingIndicator.startAnimation(nil)
        }
    }

    private var timerColor: NSColor {
        if coordinator.recordingElapsed >= Self.redThreshold {
            return blinkOn ? .systemRed : .systemRed.withAlphaComponent(0.25)
        }
        if coordinator.recordingElapsed >= Self.yellowThreshold {
            return .systemYellow
        }
        return .labelColor
    }

    private func updateBlinkTimer() {
        guard coordinator.recordingElapsed >= Self.redThreshold else {
            stopBlinkTimer(resetBlink: true)
            return
        }
        guard blinkTimer == nil else { return }

        blinkTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(handleBlinkTimer),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopBlinkTimer(resetBlink: Bool = false) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if resetBlink {
            blinkOn = true
        }
    }

    @objc private func handleStatusItemClick() {
        togglePopover()
        Self.log.info("statusItemClick complete visible=\(self.panel.isVisible, privacy: .public) isKey=\(self.panel.isKeyWindow, privacy: .public)")
    }

    @objc private func handleAppDidResignActive() {
        Self.log.info("appDidResignActive visible=\(self.panel.isVisible, privacy: .public) isKey=\(self.panel.isKeyWindow, privacy: .public)")
    }

    @objc private func handleAppDidBecomeActive() {
        coordinator.presentWelcomeIfNeeded()
    }

    @objc private func handleBlinkTimer() {
        blinkOn.toggle()
        updateStatusItem()
    }
}

private final class MenuBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 12

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MenuBarLayout.popoverWidth, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.transient, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Lets a click on the spinner reach the status button underneath it.
private final class MouseTransparentProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class PopoverChromeView: NSView {
    private let effectView = NSVisualEffectView()

    init(contentView: NSView) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = MenuBarPanel.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentView)
        addSubview(effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
}

private final class TransparentHostingView: NSHostingView<AnyView> {
    override var isOpaque: Bool { false }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
