import AppKit
import Combine
import os
import SwiftUI

enum MenuBarLayout {
    static let popoverWidth: CGFloat = 306
    static let popoverChromeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 12, right: 10)

    static var popoverPanelWidth: CGFloat {
        popoverWidth + popoverChromeInsets.left + popoverChromeInsets.right
    }
}

@MainActor
final class MenuBarController: NSObject {
    private static let log = Logger(subsystem: "WhisperKey", category: "MenuBarController")
    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55

    let coordinator: AppCoordinator

    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hostingView: TransparentHostingView
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var suppressPanelResignClose = false

    override init() {
        coordinator = AppCoordinator()
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
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        blinkTimer?.invalidate()
    }

    func togglePopover() {
        Self.log.info("togglePopover visibleBefore=\(self.panel.isVisible, privacy: .public) isKeyBefore=\(self.panel.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        if panel.isVisible {
            closePopover(reason: "toggle-visible")
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
        startMouseMonitoring()
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
        stopMouseMonitoring()
        suppressPanelResignClose = false
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

        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.toolTip = "WhisperKey"

        updateStatusItem()
    }

    private func configurePanel() {
        hostingView.rootView = AnyView(
            PopoverContent().environmentObject(coordinator)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = PopoverChromeView(contentView: hostingView)
    }

    private func updatePanelSize() {
        let insets = MenuBarLayout.popoverChromeInsets
        let fittingSize = hostingView.fittingSize
        let panelSize = NSSize(
            width: MenuBarLayout.popoverPanelWidth,
            height: fittingSize.height + insets.top + insets.bottom
        )
        panel.setContentSize(panelSize)
        panel.contentView?.layoutSubtreeIfNeeded()
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
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = panel.frame.size
        let insets = MenuBarLayout.popoverChromeInsets
        let visualHeight = max(panelSize.height - insets.top - insets.bottom, 0)

        let padding: CGFloat = 6
        let x = min(
            max(buttonFrameInScreen.midX - panelSize.width / 2, visibleFrame.minX + padding),
            visibleFrame.maxX - panelSize.width - padding
        )
        let y = buttonFrameInScreen.minY - visualHeight - padding - insets.bottom

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        Self.log.info("positionPanel buttonFrame=\(String(describing: buttonFrameInScreen), privacy: .public) visibleFrame=\(String(describing: visibleFrame), privacy: .public) panelSize=\(String(describing: panelSize), privacy: .public) origin=\(String(describing: NSPoint(x: x, y: y)), privacy: .public)")
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    private func startMouseMonitoring() {
        stopMouseMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalMouseDown(event)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    self?.closePopover(reason: "global-mouse-down", closeRelatedWindows: true)
                }
            }
            Self.log.info("globalMouseMonitoring started deferred global=\((self.globalMouseMonitor != nil), privacy: .public)")
        }
        Self.log.info("mouseMonitoring started local=\((self.localMouseMonitor != nil), privacy: .public) global=\((self.globalMouseMonitor != nil), privacy: .public)")
    }

    private func stopMouseMonitoring() {
        let hadLocalMouseMonitor = localMouseMonitor != nil
        let hadGlobalMouseMonitor = globalMouseMonitor != nil
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if hadLocalMouseMonitor || hadGlobalMouseMonitor {
            Self.log.info("mouseMonitoring stopped hadLocal=\(hadLocalMouseMonitor, privacy: .public) hadGlobal=\(hadGlobalMouseMonitor, privacy: .public)")
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }
        guard !eventIsInsideRelatedWindow(event) else { return event }

        if eventIsInsideStatusItem(event) {
            suppressPanelResignClose = true
            Self.log.info("localMouseDown inside status item suppressPanelResignClose=true eventWindow=\(String(describing: event.window), privacy: .public)")
            return event
        }

        Self.log.info("localMouseDown outside panel/status eventWindow=\(String(describing: event.window), privacy: .public) location=\(String(describing: event.locationInWindow), privacy: .public)")
        closePopover(reason: "local-mouse-outside", closeRelatedWindows: true)
        return event
    }

    private func eventIsInsideRelatedWindow(_ event: NSEvent) -> Bool {
        isRelatedWindow(event.window)
    }

    private func isRelatedWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }

        return relatedWindows.contains { relatedWindow in
            window === relatedWindow
                || window.parent === relatedWindow
                || window.sheetParent === relatedWindow
                || relatedWindow.childWindows?.contains(where: { $0 === window }) == true
                || relatedWindow.attachedSheet === window
        }
    }

    private var relatedWindows: [NSWindow] {
        [
            panel,
            SettingsWindowController.relatedWindow,
            HistoryFullWindowController.relatedWindow,
            coordinator.onboardingWindowController?.relatedWindow,
            NSApp.modalWindow,
        ].compactMap(\.self)
    }

    private func eventIsInsideStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button,
              event.window === button.window
        else { return false }

        let location = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(location)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        if case .recording = coordinator.state {
            button.title = " \(coordinator.recordingTimerText)"
            button.attributedTitle = NSAttributedString(
                string: " \(coordinator.recordingTimerText)",
                attributes: [.foregroundColor: timerColor]
            )
            updateBlinkTimer()
        } else {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            stopBlinkTimer()
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
        suppressPanelResignClose = false
        Self.log.info("statusItemClick complete suppressPanelResignClose=false visible=\(self.panel.isVisible, privacy: .public) isKey=\(self.panel.isKeyWindow, privacy: .public)")
    }

    @objc private func handleAppDidResignActive() {
        Self.log.info("appDidResignActive visible=\(self.panel.isVisible, privacy: .public) isKey=\(self.panel.isKeyWindow, privacy: .public)")
        closePopover(reason: "app-did-resign-active", closeRelatedWindows: panel.isVisible)
    }

    @objc private func handleAppDidBecomeActive() {
        coordinator.presentWelcomeIfNeeded()
    }

    @objc private func handlePanelDidResignKey() {
        Self.log.info("panelDidResignKey visible=\(self.panel.isVisible, privacy: .public) suppress=\(self.suppressPanelResignClose, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        guard !suppressPanelResignClose else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.suppressPanelResignClose else { return }
            guard !self.isRelatedWindow(NSApp.keyWindow) else {
                Self.log.info("panelDidResignKey kept open relatedKeyWindow=\(String(describing: NSApp.keyWindow), privacy: .public)")
                return
            }
            self.closePopover(reason: "panel-did-resign-key", closeRelatedWindows: true)
        }
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
            contentRect: NSRect(x: 0, y: 0, width: MenuBarLayout.popoverPanelWidth, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.transient, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PopoverChromeView: NSView {
    private let shadowView = NSView()
    private let backdrop = RoundedPopoverBackgroundView(cornerRadius: MenuBarPanel.cornerRadius)

    init(contentView: NSView) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        configureShadowView()
        configureBackdrop()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(contentView)
        addSubview(shadowView)
        addSubview(backdrop)

        let insets = MenuBarLayout.popoverChromeInsets
        NSLayoutConstraint.activate([
            shadowView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            shadowView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            shadowView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            shadowView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),

            backdrop.leadingAnchor.constraint(equalTo: shadowView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: shadowView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: shadowView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: shadowView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backdrop.updateAppearance()
    }

    private func configureShadowView() {
        shadowView.translatesAutoresizingMaskIntoConstraints = false
        shadowView.wantsLayer = true
        shadowView.layer?.backgroundColor = NSColor.clear.cgColor
        shadowView.layer?.masksToBounds = false
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.18
        shadowView.layer?.shadowRadius = 18
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    private func configureBackdrop() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updateShadowPath() {
        shadowView.layer?.shadowPath = CGPath(
            roundedRect: shadowView.bounds,
            cornerWidth: MenuBarPanel.cornerRadius,
            cornerHeight: MenuBarPanel.cornerRadius,
            transform: nil
        )
    }
}

private final class RoundedPopoverBackgroundView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        updateAppearance()
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let strokeWidth = pixelLineWidth
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )

        NSColor.windowBackgroundColor.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }

    private var pixelLineWidth: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return 1 / scale
    }
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
