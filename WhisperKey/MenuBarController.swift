import AppKit
import Combine
import os
import SwiftUI

enum MenuBarLayout {
    static let popoverWidth: CGFloat = 306
}

@MainActor
final class MenuBarController: NSObject {
    private static let log = Logger(subsystem: "WhisperKey", category: "MenuBarController")
    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55
    private static let statusIconWidth: CGFloat = 18
    private static let processingIndicatorWidth: CGFloat = 14
    private static let statusItemIconTrailingInset: CGFloat = max((NSStatusItem.squareLength - statusIconWidth) / 2, 0)
    private static let statusItemLeadingInset: CGFloat = 5
    private static let statusItemContentGap: CGFloat = 5

    let coordinator: AppCoordinator

    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hostingView: TransparentHostingView
    private let statusContentView = MouseTransparentView()
    private let statusTimerLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let processingIndicator = NSProgressIndicator(frame: .zero)
    private var statusTimerHorizontalConstraints: [NSLayoutConstraint] = []
    private var processingIndicatorHorizontalConstraints: [NSLayoutConstraint] = []
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

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.toolTip = "WhisperKey"
        configureStatusContentView(in: button)

        updateStatusItem()
    }

    private func configureStatusContentView(in button: NSStatusBarButton) {
        statusContentView.translatesAutoresizingMaskIntoConstraints = false
        statusContentView.userInterfaceLayoutDirection = .leftToRight

        statusTimerLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusTimerLabel.textColor = .labelColor
        statusTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        statusTimerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusTimerLabel.setContentHuggingPriority(.required, for: .horizontal)

        processingIndicator.style = .spinning
        processingIndicator.controlSize = .small
        processingIndicator.isIndeterminate = true
        processingIndicator.isDisplayedWhenStopped = false
        processingIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.image = Self.makeMenuBarImage()
        statusIconView.imageScaling = .scaleProportionallyDown
        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        statusContentView.addSubview(statusTimerLabel)
        statusContentView.addSubview(processingIndicator)
        statusContentView.addSubview(statusIconView)
        button.addSubview(statusContentView)

        let statusTimerHorizontalConstraints = [
            statusTimerLabel.trailingAnchor.constraint(equalTo: statusIconView.leadingAnchor, constant: -Self.statusItemContentGap),
            statusTimerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusContentView.leadingAnchor, constant: Self.statusItemLeadingInset),
        ]
        let processingIndicatorHorizontalConstraints = [
            processingIndicator.trailingAnchor.constraint(equalTo: statusIconView.leadingAnchor, constant: -Self.statusItemContentGap),
            processingIndicator.leadingAnchor.constraint(greaterThanOrEqualTo: statusContentView.leadingAnchor, constant: Self.statusItemLeadingInset),
        ]

        self.statusTimerHorizontalConstraints = statusTimerHorizontalConstraints
        self.processingIndicatorHorizontalConstraints = processingIndicatorHorizontalConstraints

        NSLayoutConstraint.activate([
            statusContentView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusContentView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusContentView.topAnchor.constraint(equalTo: button.topAnchor),
            statusContentView.bottomAnchor.constraint(equalTo: button.bottomAnchor),

            statusIconView.trailingAnchor.constraint(equalTo: statusContentView.trailingAnchor, constant: -Self.statusItemIconTrailingInset),
            statusIconView.centerYAnchor.constraint(equalTo: statusContentView.centerYAnchor),

            statusTimerLabel.centerYAnchor.constraint(equalTo: statusContentView.centerYAnchor),

            processingIndicator.centerYAnchor.constraint(equalTo: statusContentView.centerYAnchor),

            processingIndicator.widthAnchor.constraint(equalToConstant: Self.processingIndicatorWidth),
            processingIndicator.heightAnchor.constraint(equalToConstant: Self.processingIndicatorWidth),
            statusIconView.widthAnchor.constraint(equalToConstant: Self.statusIconWidth),
            statusIconView.heightAnchor.constraint(equalToConstant: Self.statusIconWidth),
        ])
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
        let iconFrameInWindow = statusIconView.convert(statusIconView.bounds, to: nil)
        let iconFrameInScreen = buttonWindow.convertToScreen(iconFrameInWindow)
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
        Self.log.info("positionPanel buttonFrame=\(String(describing: buttonFrameInScreen), privacy: .public) visibleFrame=\(String(describing: visibleFrame), privacy: .public) panelSize=\(String(describing: panelSize), privacy: .public) origin=\(String(describing: NSPoint(x: x, y: y)), privacy: .public)")
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem.button,
              let buttonWindow = button.window
        else { return nil }

        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
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

        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        statusIconView.image = Self.makeMenuBarImage()

        switch coordinator.state {
        case .recording:
            hideProcessingIndicator()
            statusTimerLabel.stringValue = coordinator.recordingTimerText
            statusTimerLabel.textColor = timerColor
            statusTimerLabel.isHidden = false
            button.toolTip = "Recording \(coordinator.recordingTimerText)"
            updateBlinkTimer()
        case .transcribing:
            stopBlinkTimer(resetBlink: true)
            statusTimerLabel.isHidden = true
            button.toolTip = "Transcribing..."
            showProcessingIndicator()
        case .idle, .error, .microphoneDenied, .accessibilityDenied:
            hideProcessingIndicator()
            statusTimerLabel.isHidden = true
            button.toolTip = "WhisperKey"
            stopBlinkTimer(resetBlink: true)
        }

        updateStatusItemLength()
    }

    private static func makeMenuBarImage() -> NSImage? {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }

    private func showProcessingIndicator() {
        processingIndicator.isHidden = false
        processingIndicator.startAnimation(nil)
    }

    private func hideProcessingIndicator() {
        processingIndicator.stopAnimation(nil)
        processingIndicator.isHidden = true
    }

    private func updateStatusItemLength() {
        let showsTimer = !statusTimerLabel.isHidden
        let showsProcessingIndicator = !processingIndicator.isHidden

        statusTimerHorizontalConstraints.forEach { $0.isActive = showsTimer }
        processingIndicatorHorizontalConstraints.forEach { $0.isActive = showsProcessingIndicator }

        guard showsTimer || showsProcessingIndicator else {
            statusItem.length = NSStatusItem.squareLength
            statusItem.button?.layoutSubtreeIfNeeded()
            return
        }

        var length = Self.statusItemLeadingInset + Self.statusIconWidth + Self.statusItemIconTrailingInset
        if showsTimer {
            length += Self.statusItemContentGap + ceil(statusTimerLabel.intrinsicContentSize.width)
        } else if showsProcessingIndicator {
            length += Self.statusItemContentGap + Self.processingIndicatorWidth
        }

        statusItem.length = max(NSStatusItem.squareLength, length)
        statusItem.button?.layoutSubtreeIfNeeded()
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

private final class MouseTransparentView: NSView {
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
