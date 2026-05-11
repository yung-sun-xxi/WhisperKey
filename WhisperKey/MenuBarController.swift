import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private static let yellowThreshold: TimeInterval = 9 * 60 + 30
    private static let redThreshold: TimeInterval = 9 * 60 + 55

    let coordinator: AppCoordinator

    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let hostingView: TransparentHostingView<AnyView>
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer: Timer?
    private var blinkOn = true

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

        coordinator.openMenuBarPopoverHandler = { [weak self] in
            self?.showPopover()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        blinkTimer?.invalidate()
    }

    func togglePopover() {
        if panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        NSApp.activate(ignoringOtherApps: true)
        updatePanelSize()
        positionPanel()
        panel.orderFrontRegardless()
        statusItem.button?.state = .on
        clearPanelFocus()
    }

    func closePopover() {
        panel.orderOut(nil)
        statusItem.button?.state = .off
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

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = MenuBarPanel.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])

        panel.contentView = backdrop
    }

    private func updatePanelSize() {
        panel.contentView?.frame.size.width = 360
        panel.contentView?.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        panel.setContentSize(NSSize(width: 360, height: fittingSize.height))
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameInScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = panel.frame.size

        let padding: CGFloat = 6
        let x = min(
            max(buttonFrameInScreen.midX - panelSize.width / 2, visibleFrame.minX + padding),
            visibleFrame.maxX - panelSize.width - padding
        )
        let y = buttonFrameInScreen.minY - panelSize.height - padding

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func clearPanelFocus() {
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(nil)
        }
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
    }

    @objc private func handleAppDidResignActive() {
        closePopover()
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = Self.cornerRadius
        contentView?.layer?.masksToBounds = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
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
