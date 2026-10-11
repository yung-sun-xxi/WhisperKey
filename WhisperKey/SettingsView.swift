import AppKit
import AVFoundation
import Combine
import SwiftUI
import ThemeKit
import HotkeyEngine
import QuickPaste
import SettingsStore
import TranscriptionProvider
import HistoryStore
import UsageStatsStore
#if DEBUG
import DevBuildMarker
import os
#endif

// MARK: - Themed Settings begin

enum SettingsWindowLayout {
    static let windowTitle = "WhisperKey Settings"
}

#if DEBUG
/// What the Settings window's views and controllers did, in order, for checking a theme
/// or tab switch on the installed dev app:
/// `/usr/bin/log show --last 5m --info --predicate 'subsystem == "WhisperKey" AND category == "SettingsWindow"'`.
let settingsWindowLog = Logger(subsystem: "WhisperKey", category: "SettingsWindow")
#endif

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static let delegate = SettingsWindowDelegate()

    static var relatedWindow: NSWindow? {
        window
    }

    /// Posted when the settings window is torn down, so a pane can cancel work that
    /// would otherwise outlive it. Switching tabs does not post this.
    static let willCloseNotification = Notification.Name("WhisperKeySettingsWindowWillClose")

    static func prepare(coordinator: AppCoordinator) {
        #if DEBUG
        SettingsSnapshotHook.startIfRequested(coordinator: coordinator)
        #endif

        guard window == nil else { return }

        let preparedWindow = makeWindow(coordinator: coordinator)
        window = preparedWindow
    }

    /// The panes' identifiers, in the order the window shows them.
    static var tabIdentifiers: [String] {
        SettingsTab.allCases.map(\.identifier)
    }

    /// Shows the pane with `identifier` in the open window. False when there is no
    /// window or no such pane.
    @discardableResult
    static func selectTab(identifier: String) -> Bool {
        guard let controller = window?.contentViewController as? SettingsContentViewController else {
            return false
        }
        return controller.selectTab(identifier: identifier)
    }

    static func hide() {
        TransientWindowStack.shared.unregister(id: "settings")

        guard let closingWindow = window else { return }

        // Close instead of ordering out so SwiftUI-owned transient state is rebuilt next time.
        window = nil
        NotificationCenter.default.post(name: willCloseNotification, object: closingWindow)
        UsageResetWindowController.hide()
        dismissModalUI(attachedTo: closingWindow)
        closingWindow.close()
    }

    static func show(coordinator: AppCoordinator) {
        if let existing = window {
            present(existing)
            return
        }

        let window = makeWindow(coordinator: coordinator)
        Self.window = window
        present(window)
    }

    static func windowDidClose(_ closedWindow: NSWindow) {
        if window === closedWindow {
            TransientWindowStack.shared.unregister(id: "settings")
            window = nil
            NotificationCenter.default.post(name: willCloseNotification, object: closedWindow)
        }
    }

    private static func makeWindow(coordinator: AppCoordinator) -> NSWindow {
        let contentController = SettingsContentViewController(coordinator: coordinator)

        let window = SettingsWindow(contentViewController: contentController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = SettingsWindowLayout.windowTitle
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.initialFirstResponder = contentController.focusParkingView
        window.delegate = delegate
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // The theme's chrome and the selected pane's size, before the window is placed.
        contentController.attachChrome(to: window)
        window.center()

        return window
    }

    private static func present(_ window: NSWindow) {
        activateApp()
        focus(window)
        focusParkingView(in: window)
        TransientWindowStack.shared.register(
            id: "settings",
            layer: .secondary,
            window: window
        ) {
            SettingsWindowController.hide()
        }

        DispatchQueue.main.async { [weak window] in
            guard let window else { return }

            activateApp()
            focus(window)
            focusParkingView(in: window)
        }
    }

    private static func focus(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.orderFrontRegardless()
    }

    private static func dismissModalUI(attachedTo settingsWindow: NSWindow) {
        if let attachedSheet = settingsWindow.attachedSheet {
            settingsWindow.endSheet(attachedSheet, returnCode: .cancel)
            attachedSheet.orderOut(nil)
        }

        guard let modalWindow = NSApp.modalWindow,
              modalWindow !== settingsWindow
        else { return }

        NSApp.stopModal(withCode: .cancel)
        modalWindow.orderOut(nil)
    }

    private static func focusParkingView(in window: NSWindow) {
        guard let initialFirstResponder = window.initialFirstResponder else {
            window.makeFirstResponder(nil)
            return
        }

        window.makeFirstResponder(initialFirstResponder)
    }

    private static func activateApp() {
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        Task { @MainActor in
            SettingsWindowController.windowDidClose(closedWindow)
        }
    }
}

/// Which pane the tab well shows. The tab well writes it; the tab view controller under it
/// follows.
@MainActor
private final class SettingsTabSelection: ObservableObject {
    @Published var index = 0
}

/// The window's content: the header (the drawn titlebar in Midnight, then the tab well)
/// above the tab view controller that holds the panes. The window is as tall as the
/// header plus the selected pane, and as wide as the theme says; it follows both, and
/// the theme's window chrome, while open.
private final class SettingsContentViewController: NSViewController {
    let focusParkingView = FirstResponderParkingView(frame: .zero)

    private let selection: SettingsTabSelection
    private let tabs: SettingsTabsController
    private let header: SettingsHeaderHostingView
    private var chrome: ThemedWindowChrome?
    private var subscriptions: Set<AnyCancellable> = []
    private var isResizingWindow = false

    init(coordinator: AppCoordinator) {
        ThemeTokensSource.shared.follow(coordinator.settings)

        let selection = SettingsTabSelection()
        self.selection = selection
        tabs = SettingsTabsController(coordinator: coordinator)
        header = SettingsHeaderHostingView(rootView: AnyView(
            ThemedRoot("settings.header") {
                SettingsHeader(selection: selection)
            }
        ))

        super.init(nibName: nil, bundle: nil)

        header.sizingOptions = [.intrinsicContentSize]
        // The drawn bar takes the titlebar's place. Under a transparent titlebar the
        // titlebar's safe area would push the header down by the system titlebar's height.
        header.safeAreaRegions = []
        tabs.onSelectedPaneSizeChange = { [weak self] in
            self?.resizeWindowToSelectedPane()
        }
        header.onIntrinsicSizeChange = { [weak self] in
            self?.resizeWindowToSelectedPane()
        }
        // Both publishers fire in `willSet`, before the value changes. Acting there would
        // lay the header and panes out while they still read the old value, and SwiftUI
        // would take that as their update for the change and not draw them again. So
        // the work runs on the next turn of the main queue, once the value is stored.
        selection.$index
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak selection] _ in
                guard let self, let selection else { return }
                #if DEBUG
                settingsWindowLog.info("selection applied index=\(selection.index, privacy: .public)")
                #endif
                self.showPane(at: selection.index)
            }
            .store(in: &subscriptions)
        ThemeTokensSource.shared.$tokens
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let tokens = ThemeTokensSource.shared.tokens
                #if DEBUG
                settingsWindowLog.info("theme applied theme=\(tokens.theme.rawValue, privacy: .public)")
                #endif
                self?.applyTheme(tokens)
            }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let container = NSView()
        addChild(tabs)
        let paneView = tabs.view

        for subview in [header, paneView, focusParkingView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: header.bottomAnchor),
            paneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            focusParkingView.widthAnchor.constraint(equalToConstant: 0),
            focusParkingView.heightAnchor.constraint(equalToConstant: 0),
            focusParkingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            focusParkingView.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        view = container
    }

    /// Gives the window the current theme's chrome and the selected pane's size.
    func attachChrome(to window: NSWindow) {
        chrome = ThemedWindowChrome(window: window)
        applyTheme(ThemeTokensSource.shared.tokens)
    }

    func selectTab(identifier: String) -> Bool {
        guard let index = TabWellSelection.index(of: identifier, in: SettingsWindowController.tabIdentifiers) else {
            return false
        }
        selection.index = index
        return true
    }

    private func showPane(at index: Int) {
        let index = TabWellSelection.clamped(index, count: tabs.tabViewItems.count)
        guard tabs.selectedTabViewItemIndex != index else { return }
        tabs.selectedTabViewItemIndex = index
    }

    private func applyTheme(_ tokens: ThemeTokens) {
        chrome?.apply(tokens, background: tokens.colors.settingsSurface)
        // Every pane takes the new theme now, the hidden ones too, so each reports its
        // new size before it is next shown.
        tabs.layOutEveryPane()
        resizeWindowToSelectedPane(tokens)
        // The panes and the header redraw in the new theme on the next pass; size again
        // once they have.
        DispatchQueue.main.async { [weak self] in
            self?.resizeWindowToSelectedPane()
        }
    }

    private func windowContentSize(_ tokens: ThemeTokens) -> NSSize {
        loadViewIfNeeded()
        header.layoutSubtreeIfNeeded()
        let height = header.fittingSize.height + tabs.selectedPaneHeight
        return NSSize(width: tokens.settingsWindow.width, height: ceil(height))
    }

    /// Keeps the window's top-left corner where it is: resizing from the bottom-left
    /// would walk the window up the screen on every tab switch.
    private func resizeWindowToSelectedPane(_ newTokens: ThemeTokens? = nil) {
        guard !isResizingWindow, let window = view.window else { return }

        let size = windowContentSize(newTokens ?? ThemeTokensSource.shared.tokens)
        guard size.height > 1 else { return }

        isResizingWindow = true
        defer { isResizingWindow = false }

        // The content runs under the titlebar when the chrome is drawn, so the frame is
        // the content's own size; otherwise the system titlebar sits on top of it.
        let frameSize = window.styleMask.contains(.fullSizeContentView)
            ? size
            : window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = window.frame
        frame.origin.y = frame.maxY - frameSize.height
        frame.size = frameSize
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
        #if DEBUG
        settingsWindowLog.info("window resized content=\(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) frame=\(Int(window.frame.width), privacy: .public)x\(Int(window.frame.height), privacy: .public)")
        #endif
        chrome?.placeTrafficLights()
    }
}

/// The panes, one per tab, without tabs of their own: the tab well above picks them. Each
/// pane is its own hosting controller, so the state a pane owns — the API key draft above
/// all — is not rebuilt when the selection changes.
private final class SettingsTabsController: NSTabViewController {
    /// Called when the selected pane changes, or changes its height.
    var onSelectedPaneSizeChange: (() -> Void)?

    init(coordinator: AppCoordinator) {
        super.init(nibName: nil, bundle: nil)

        tabStyle = .unspecified
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false

        for tab in SettingsTab.allCases {
            let paneController = NSHostingController(
                rootView: AnyView(
                    ThemedRoot("settings.\(tab.title)") {
                        SettingsPane(tab: tab, settings: coordinator.settings)
                            .environmentObject(coordinator)
                    }
                )
            )
            // Reports the SwiftUI content height back as the pane's preferred size, which
            // is what drives the window resize.
            paneController.sizingOptions = [.preferredContentSize]
            paneController.title = SettingsWindowLayout.windowTitle

            let item = NSTabViewItem(viewController: paneController)
            item.identifier = tab.identifier
            item.label = tab.title
            addTabViewItem(item)
        }

        selectedTabViewItemIndex = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)

        onSelectedPaneSizeChange?()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)

        guard viewController === selectedPaneController else { return }

        onSelectedPaneSizeChange?()
    }

    /// Lays out every pane, shown or not, so each draws in the current theme and
    /// reports its size.
    func layOutEveryPane() {
        for item in tabViewItems {
            guard let paneController = item.viewController else { continue }
            paneController.loadViewIfNeeded()
            paneController.view.needsLayout = true
            paneController.view.layoutSubtreeIfNeeded()
            #if DEBUG
            settingsWindowLog.info("pane laid out tab=\((item.identifier as? String) ?? "", privacy: .public) preferred=\(Int(paneController.preferredContentSize.width), privacy: .public)x\(Int(paneController.preferredContentSize.height), privacy: .public)")
            #endif
        }
    }

    var selectedPaneHeight: CGFloat {
        guard let paneController = selectedPaneController else { return 0 }

        paneController.loadViewIfNeeded()
        let paneView = paneController.view
        paneView.layoutSubtreeIfNeeded()

        let preferredHeight = paneController.preferredContentSize.height
        return preferredHeight > 1 ? preferredHeight : paneView.fittingSize.height
    }

    private var selectedPaneController: NSViewController? {
        let index = selectedTabViewItemIndex
        guard index >= 0, index < tabViewItems.count else { return nil }

        return tabViewItems[index].viewController
    }
}

/// Reports a change of the header's height, so the window follows it.
private final class SettingsHeaderHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()

        guard let onIntrinsicSizeChange else { return }
        DispatchQueue.main.async(execute: onIntrinsicSizeChange)
    }
}

/// The drawn titlebar (Midnight only) and the tab well.
private struct SettingsHeader: View {
    @ObservedObject var selection: SettingsTabSelection
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        #if DEBUG
        let _ = settingsWindowLog.info("header body theme=\(tokens.theme.rawValue, privacy: .public) selected=\(selection.index, privacy: .public) source=\(ThemeTokensSource.shared.tokens.theme.rawValue, privacy: .public)")
        #endif
        VStack(spacing: 0) {
            ThemedTitleBar(title: SettingsWindowLayout.windowTitle)
            ThemedTabWell(titles: SettingsTab.allCases.map(\.title), selection: $selection.index)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private final class SettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performZoom(_ sender: Any?) {
        // Disable title-bar double-click zoom for this utility window.
    }
}

private final class FirstResponderParkingView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }
}

// MARK: - Themed Settings end

struct PopoverContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    private static let contentInsets = EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = PermissionBanner(coordinator: coordinator) {
                    banner
                }
                CommandCenterHeader(
                    settings: coordinator.settings,
                    usageStats: coordinator.usageStats,
                    appState: coordinator.state,
                    cancelAction: coordinator.cancelActiveOperation
                )
                HistorySection(history: coordinator.history, coordinator: coordinator)
                Divider()
                    .opacity(0.55)
                HStack {
                    Button {
                        coordinator.openSettingsWindow()
                    } label: {
                        Text("Settings")
                            .font(.system(size: 12, weight: .regular))
                    }
                    .keyboardShortcut(",", modifiers: [.command])
                    Spacer()
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("Quit")
                            .font(.system(size: 12, weight: .regular))
                    }
                        .keyboardShortcut("q")
                }
            }
            .padding(Self.contentInsets)
        }
        .frame(width: MenuBarLayout.popoverWidth)
        .font(PopoverTypography.base)
        .foregroundColor(PopoverTypography.primaryColor)
    }
}

private struct PermissionBanner: View {
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    init?(coordinator: AppCoordinator) {
        if !coordinator.permissions.accessibilityGranted {
            self.title = "Accessibility access required"
            self.message = "Enable WhisperKey under Privacy & Security → Accessibility."
            self.buttonTitle = "Open System Settings"
            self.action = coordinator.openAccessibilitySettings
        } else if !coordinator.permissions.microphoneGranted {
            self.title = "Microphone access required"
            self.message = "Enable WhisperKey under Privacy & Security → Microphone."
            self.buttonTitle = coordinator.permissions.microphoneStatus == .notDetermined
                ? "Allow Microphone"
                : "Open System Settings"
            self.action = coordinator.permissions.microphoneStatus == .notDetermined
                ? coordinator.requestMicrophonePermission
                : coordinator.openMicrophoneSettings
        } else {
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(PopoverTypography.sectionTitle)
                .foregroundColor(PopoverTypography.primaryColor)
            Text(message)
                .font(PopoverTypography.base)
                .foregroundColor(PopoverTypography.secondaryColor)
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

#if DEBUG
/// Marks the dev app's popover with the same letter as its menu bar icon (#149).
private struct DevBuildBadge: View {
    var body: some View {
        Text(DevBuildMarker.letter)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(PopoverTypography.secondaryColor)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(PopoverTypography.secondaryColor.opacity(0.6), lineWidth: 1)
            )
            .help("WhisperKey Dev (Debug build)")
            .accessibilityLabel("Dev build")
    }
}
#endif

private struct CommandCenterHeader: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var usageStats: UsageStatsStore
    let appState: AppCoordinator.AppState
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            usageSummaryButton

            HeaderPeriodPicker(selection: $settings.usageStatsRange)

            HStack(spacing: 12) {
                HeaderOutputToggle(
                    title: "Clipboard",
                    isOn: $settings.saveTranscriptionToClipboard,
                    alignment: .leading
                )
                HeaderVerticalDivider()
                HeaderOutputToggle(
                    title: "Auto-paste",
                    isOn: $settings.autoPasteTranscription,
                    alignment: .trailing
                )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(PopoverTypography.secondaryColor)
                    .frame(width: 14, height: 14, alignment: .center)
                Text("\(settings.provider.shortDisplayName) · \(settings.currentTranscriptionModelID)")
                    .font(PopoverTypography.caption)
                    .foregroundColor(PopoverTypography.primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
            }
            .help("\(settings.provider.displayName) · \(settings.currentTranscriptionModelID)")

            Spacer(minLength: 8)

            #if DEBUG
            DevBuildBadge()
            #endif

            statusControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusControl: some View {
        switch appState {
        case .starting, .recording, .transcribing:
            cancelStatusButton
        case .idle, .error, .microphoneDenied, .accessibilityDenied:
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 18, height: 18)
            .accessibilityLabel("Active")
        }
    }

    /// Every provider and model in the period, not just the selected one (#139).
    private var summary: UsageSummary {
        usageStats.totalSummary(range: settings.usageStatsRange)
    }

    /// The whole summary bar opens the per-model breakdown; a chevron inside it says so.
    private var usageSummaryButton: some View {
        Button {
            UsageBreakdownWindowController.show(usageStats: usageStats, settings: settings)
        } label: {
            UsageSummaryRow(summary: summary, showsDisclosure: true)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Usage by model")
    }

    private var cancelStatusButton: some View {
        Button(action: cancelAction) {
            CancelStatusIcon()
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(cancelHelpText)
        .accessibilityLabel(cancelHelpText)
    }

    private var cancelHelpText: String {
        switch appState {
        case .starting:
            "Cancel microphone startup"
        case .recording:
            "Stop and save recording"
        case .transcribing:
            "Cancel processing"
        case .idle, .error, .microphoneDenied, .accessibilityDenied:
            "Cancel"
        }
    }
}

/// Red circle with a white stop square, both drawn from the same center
/// point, so they can never drift apart the way an SF Symbol overlay can
/// (symbol glyphs are not centered within their image bounds).
private struct CancelStatusIcon: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.84

            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(circle, with: .color(.red.opacity(0.84)))

            let halfSide = radius * 0.4
            let square = Path(roundedRect: CGRect(
                x: center.x - halfSide,
                y: center.y - halfSide,
                width: halfSide * 2,
                height: halfSide * 2
            ), cornerRadius: halfSide * 0.35)
            context.fill(square, with: .color(.white))
        }
    }
}

private struct UsageSummaryRow: View {
    let summary: UsageSummary
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 0) {
            UsageMetricColumn(value: UsageLineFormatter.wordsLabel(summary.wordCount), label: "words")
            HeaderVerticalDivider()
            UsageMetricColumn(value: UsageLineFormatter.compactAudioDurationLabel(summary.audioDurationSeconds), label: "audio")
            HeaderVerticalDivider()
            UsageMetricColumn(value: costText ?? "-", label: nil)
            if showsDisclosure {
                // Its own segment, so the three figures keep equal widths.
                HeaderVerticalDivider()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(PopoverTypography.primaryColor.opacity(0.62))
                    .frame(width: 26)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 7))
        .help(showsDisclosure
            ? "\(UsageLineFormatter.line(from: summary)). Click for usage by model."
            : UsageLineFormatter.line(from: summary))
    }

    private var costText: String? {
        guard let cost = summary.estimatedCost, let currency = summary.currency else {
            return nil
        }
        return UsageLineFormatter.compactApproximateCostLabel(cost, currency: currency)
    }
}

private struct UsageMetricColumn: View {
    let value: String
    let label: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundColor(PopoverTypography.primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PopoverTypography.primaryColor.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 31, alignment: .center)
    }
}

struct HeaderPeriodPicker: View {
    @Binding var selection: UsageStatsRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UsageStatsRange.allCases, id: \.self) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.compactLabel)
                        .font(PopoverTypography.button)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 21)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(selection == range ? Color.white : PopoverTypography.primaryColor)
                .background {
                    if selection == range {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor)
                    }
                }
                .help(range.displayName)
            }
        }
        .padding(1.5)
        .frame(maxWidth: .infinity)
        .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 7))
        .help("Choose the usage stats range")
    }
}

private struct HeaderOutputToggle: View {
    let title: String
    @Binding var isOn: Bool
    let alignment: Alignment

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(PopoverTypography.base)
                .foregroundColor(PopoverTypography.primaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct HeaderVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(HeaderSurfaceColor.divider)
            .frame(width: 1, height: 24)
    }
}

enum HeaderSurfaceColor {
    static let bar = Color.primary.opacity(0.075)
    static let divider = Color.primary.opacity(0.14)
}

enum UsageLineFormatter {
    static func line(from summary: UsageSummary) -> String {
        let words = wordsLabel(summary.wordCount)
        let time = audioDurationLabel(summary.audioDurationSeconds)
        var parts: [String] = ["\(words) words", time]
        if let cost = summary.estimatedCost, let currency = summary.currency {
            parts.append(approximateCostLabel(cost, currency: currency))
        }
        return parts.joined(separator: " · ")
    }

    static func wordsLabel(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let value = Double(count) / 1_000
        return String(format: value >= 10 ? "%.0fk" : "%.1fk", value)
    }

    static func audioDurationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        let remainingSeconds = total % 60
        return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
    }

    static func compactAudioDurationLabel(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0m" }

        let roundedMinutes = max(Int((seconds / 60).rounded()), 1)
        if roundedMinutes < 60 {
            return "\(roundedMinutes)m"
        }

        let hours = roundedMinutes / 60
        let minutes = roundedMinutes % 60
        return minutes == 0
            ? "\(hours)h"
            : "\(hours)h \(minutes)m"
    }

    static func costLabel(_ amount: Double, currency: String) -> String {
        switch currency.uppercased() {
        case "USD":
            if amount < 0.01 && amount > 0 {
                return "<$0.01"
            }
            return String(format: "$%.2f", amount)
        default:
            return String(format: "%.2f %@", amount, currency.uppercased())
        }
    }

    static func approximateCostLabel(_ amount: Double, currency: String) -> String {
        approximated(costLabel(amount, currency: currency), amount: amount)
    }

    static func compactApproximateCostLabel(_ amount: Double, currency: String) -> String {
        approximated(compactCostLabel(amount, currency: currency), amount: amount)
    }

    /// "<$0.01" already states an upper bound and a zero cost is exact, so in
    /// both cases the "~" would be redundant.
    private static func approximated(_ label: String, amount: Double) -> String {
        guard amount > 0, !label.hasPrefix("<") else { return label }
        return "~\(label)"
    }

    static func compactCostLabel(_ amount: Double, currency: String) -> String {
        switch currency.uppercased() {
        case "USD":
            if amount < 0.01 && amount > 0 {
                return "<$0.01"
            }
            return String(format: "$%.1f", amount)
        default:
            return String(format: "%.1f %@", amount, currency.uppercased())
        }
    }
}

// MARK: - Themed Settings begin

/// One pane per tab, in the order the tab well shows them.
private enum SettingsTab: CaseIterable {
    case general
    case recording
    case transcription
    case quickPaste

    var title: String {
        switch self {
        case .transcription:
            return "Transcription"
        case .recording:
            return "Recording"
        case .quickPaste:
            return "Quick paste"
        case .general:
            return "General"
        }
    }

    var identifier: String {
        switch self {
        case .transcription:
            return "transcription"
        case .recording:
            return "recording"
        case .quickPaste:
            return "quickPaste"
        case .general:
            return "general"
        }
    }
}

/// The row area every pane shares: one width for all four, the theme's padding and
/// surface.
private struct SettingsPane: View {
    let tab: SettingsTab
    @ObservedObject var settings: SettingsStore
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        let window = tokens.settingsWindow
        #if DEBUG
        let _ = settingsWindowLog.info("pane body tab=\(tab.identifier, privacy: .public) theme=\(tokens.theme.rawValue, privacy: .public) source=\(ThemeTokensSource.shared.tokens.theme.rawValue, privacy: .public)")
        #endif
        paneContent
            .padding(.top, window.rowAreaTop)
            .padding(.bottom, window.rowAreaBottom)
            .padding(.horizontal, window.textEdge)
            .frame(width: window.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(tokens.colors.settingsSurface.color)
    }

    @ViewBuilder private var paneContent: some View {
        switch tab {
        case .transcription:
            TranscriptionSettingsPane(settings: settings)
        case .recording:
            RecordingSettingsPane(settings: settings)
        case .quickPaste:
            QuickPasteSettingsPane(settings: settings)
        case .general:
            GeneralSettingsPane(settings: settings)
        }
    }
}

private struct SettingsPaneStack<Content: View>: View {
    @Environment(\.themeTokens) private var tokens
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.settingsWindow.rowSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptionSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @State private var ownerWindow: NSWindow?
    @State private var apiKeyDraft = ""
    @State private var apiKeyValidationState = APIKeyValidationState.idle
    @State private var apiKeyValidationTask: Task<Void, Never>?
    @State private var apiKeyValidationNotice: APIKeyValidationNotice?
    /// The draft and its validation must survive a tab switch, so the first-appearance
    /// reset runs once per window rather than once per appearance.
    @State private var hasPreparedAPIKeyInput = false
    @FocusState private var apiKeyFieldFocused: Bool
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Provider") {
                ThemedPopUpPicker(
                    "Provider",
                    selection: $settings.provider,
                    options: TranscriptionProviderID.allCases,
                    title: \.displayName
                )
            }
            SettingsRow("Model") {
                modelPicker
            }
            SettingsRow("API Key") {
                apiKeyField
            }
            SettingsRow("Language") {
                ThemedPopUpPicker(
                    "Language",
                    selection: $settings.language,
                    options: TranscriptionLanguage.allCases,
                    title: \.displayName
                )
            }
        }
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
        .alert(item: $apiKeyValidationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            guard !hasPreparedAPIKeyInput else { return }

            hasPreparedAPIKeyInput = true
            resetAPIKeyInput(resetState: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.willCloseNotification)) { _ in
            // Tied to the window going away rather than to the view disappearing: a tab
            // switch takes this pane out of the window and must not cancel a validation.
            apiKeyValidationTask?.cancel()
            apiKeyValidationTask = nil
        }
        .onChange(of: settings.provider) {
            resetAPIKeyInput(resetState: true)
        }
        .onChange(of: currentAPIKey) {
            guard apiKeyValidationState != .checking else { return }
            resetAPIKeyInput(resetState: false)
        }
    }

    @ViewBuilder private var modelPicker: some View {
        switch settings.provider {
        case .openai:
            ThemedPopUpPicker(
                "Model",
                selection: $settings.openAIModel,
                options: OpenAIProvider.Model.allCases,
                title: \.rawValue
            )
        case .groq:
            ThemedPopUpPicker(
                "Model",
                selection: $settings.groqModel,
                options: GroqProvider.Model.allCases,
                title: \.displayName
            )
        }
    }

    @ViewBuilder private var apiKeyField: some View {
        HStack(spacing: tokens.controlMetrics.rowControlGap) {
            if let status = apiKeyValidationState.status {
                APIKeyValidationBadge(status: status)
            }

            Button {
                scheduleAPIKeyValidation(presentNotice: true, debounceNanoseconds: 0)
            } label: {
                Image(systemName: "checkmark.shield")
                    .font(tokens.type.actionGlyph.font)
            }
            .buttonStyle(.borderless)
            .settingsControlFrame(tokens)
            .foregroundStyle((apiKeyValidationState.isAccepted ? tokens.colors.success : tokens.colors.actionGlyph).color)
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKeyValidationState == .checking)
            .help("Validate and save API key")
            .accessibilityLabel("Validate and save API key")

            ThemedSecureField(apiKeyPlaceholder, text: $apiKeyDraft, focus: $apiKeyFieldFocused)
                .onSubmit {
                    scheduleAPIKeyValidation(presentNotice: true, debounceNanoseconds: 0)
                }
                .onChange(of: apiKeyDraft) { _, _ in
                    handleAPIKeyDraftChange()
                }

            if !currentAPIKey.isEmpty {
                Button(role: .destructive) {
                    let provider = settings.provider
                    APIKeyDeletionConfirmation.present(from: ownerWindow) {
                        clearAPIKey(for: provider)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(tokens.type.actionGlyph.font)
                }
                .buttonStyle(.borderless)
                .settingsControlFrame(tokens)
                .foregroundStyle(tokens.colors.destructiveGlyph.color)
                .help("Delete saved API key")
                .accessibilityLabel("Delete saved API key")
            }
        }
        .frame(height: tokens.sizes.control, alignment: .center)
    }

    private var currentAPIKey: String {
        switch settings.provider {
        case .openai:
            settings.openAIAPIKey
        case .groq:
            settings.groqAPIKey
        }
    }

    private var apiKeyPlaceholder: String {
        if !currentAPIKey.isEmpty {
            return "••••••••••••"
        }

        switch settings.provider {
        case .openai:
            return "sk-…"
        case .groq:
            return "gsk_…"
        }
    }

    private func handleAPIKeyDraftChange() {
        apiKeyValidationTask?.cancel()
        apiKeyValidationTask = nil
        apiKeyValidationState = .idle
    }

    private func scheduleAPIKeyValidation(
        presentNotice: Bool,
        debounceNanoseconds: UInt64 = 700_000_000
    ) {
        apiKeyValidationTask?.cancel()

        let provider = settings.provider
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiKeyValidationState = .idle
            return
        }

        apiKeyValidationTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled,
                  provider == settings.provider,
                  key == apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }

            apiKeyValidationState = .checking
            let result = await validateAPIKey(key, for: provider)

            guard !Task.isCancelled,
                  provider == settings.provider,
                  key == apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }

            applyAPIKeyValidationResult(result, key: key, provider: provider, presentNotice: presentNotice)
        }
    }

    private func validateAPIKey(_ key: String, for provider: TranscriptionProviderID) async -> APIKeyValidationResult {
        switch provider {
        case .openai:
            return await OpenAIProvider.validateAPIKey(key)
        case .groq:
            return await GroqProvider.validateAPIKey(key)
        }
    }

    private func applyAPIKeyValidationResult(
        _ result: APIKeyValidationResult,
        key: String,
        provider: TranscriptionProviderID,
        presentNotice: Bool
    ) {
        switch result {
        case .accepted:
            saveAPIKey(key, for: provider)
            apiKeyValidationState = .accepted("API key saved")
            clearAPIKeyFieldFocus()
        case .rejected(let message):
            apiKeyValidationState = .rejected(message)
        case .unavailable(let message):
            apiKeyValidationState = .unavailable(message)
        }

        guard presentNotice else { return }
        apiKeyValidationNotice = APIKeyValidationNotice(result: result)
    }

    private func saveAPIKey(_ key: String, for provider: TranscriptionProviderID) {
        switch provider {
        case .openai:
            settings.openAIAPIKey = key
        case .groq:
            settings.groqAPIKey = key
        }
    }

    private func clearAPIKey(for provider: TranscriptionProviderID) {
        apiKeyValidationTask?.cancel()
        apiKeyValidationTask = nil
        settings.deleteAPIKey(for: provider)
        if provider == settings.provider {
            apiKeyDraft = ""
            apiKeyValidationState = .idle
            clearAPIKeyFieldFocus()
        }
    }

    private func clearAPIKeyFieldFocus() {
        apiKeyFieldFocused = false
        DispatchQueue.main.async {
            let window = ownerWindow ?? SettingsWindowController.relatedWindow
            window?.makeFirstResponder(nil)
        }
    }

    private func resetAPIKeyInput(resetState: Bool) {
        apiKeyValidationTask?.cancel()
        apiKeyValidationTask = nil
        apiKeyDraft = ""
        if resetState {
            apiKeyValidationState = currentAPIKey.isEmpty ? .idle : .accepted("API key saved")
        }
    }
}

private struct RecordingSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator

    private var isRecording: Bool {
        coordinator.state == .starting || coordinator.state == .recording
    }

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Trigger") {
                ThemedPopUpPicker(
                    "Trigger",
                    selection: $settings.triggerKey,
                    options: TriggerKey.allCases,
                    title: \.displayName
                )
                .disabled(isRecording)
                .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Mode") {
                ThemedSegmentedPicker(
                    "Mode",
                    selection: $settings.triggerMode,
                    options: TriggerMode.allCases,
                    title: \.displayName
                )
                .disabled(isRecording)
                .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Esc to cancel record") {
                ThemedToggle("Esc to cancel record", isOn: $settings.escapeToCancelRecording)
                    .disabled(isRecording)
                    .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Sound effects") {
                ThemedToggle("Sound effects", isOn: $settings.soundEffectsEnabled)
            }
            SettingsRow("Pause Apple Music while recording") {
                ThemedToggle("Pause Apple Music while recording", isOn: $settings.pauseAppleMusicWhileRecording)
                    .help("Pauses Apple Music at the start of a recording and resumes it when the microphone stops.")
            }
        }
    }
}

private struct QuickPasteSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.themeTokens) private var tokens

    /// Stated because it is invisible from the settings screen otherwise: dictated text
    /// only reaches the popup by way of the clipboard.
    static let quickPasteHelp = """
        Hold the popup trigger to pick from the last few things on the clipboard and paste \
        without leaving the field you are typing in. Dictated text reaches the popup only \
        while Clipboard is on: with Clipboard off and Auto-paste on, transcriptions never \
        touch the clipboard and so never appear here.
        """

    /// Held in milliseconds because that is the unit the setting is stated in; the store
    /// keeps seconds, and it is the store that clamps.
    static let holdMillisecondsRange: ClosedRange<Int> = Int((SettingsStore.quickPasteHoldDurationRange.lowerBound * 1000).rounded())...Int((SettingsStore.quickPasteHoldDurationRange.upperBound * 1000).rounded())

    private var isRecording: Bool {
        coordinator.state == .starting || coordinator.state == .recording
    }

    private var holdMilliseconds: Binding<Int> {
        Binding(
            get: { Int((settings.quickPasteHoldDuration * 1000).rounded()) },
            set: { settings.quickPasteHoldDuration = Double($0) / 1000 }
        )
    }

    /// Parsed so the bold key name renders; falls back to the plain string rather than
    /// showing nothing if the Markdown ever fails to parse. Inline-only, whitespace kept:
    /// full-document parsing would collapse the double spaces around the separators.
    private var quickPasteUsageHint: AttributedString {
        let hint = QuickPasteConfiguration.usageHint(for: settings.quickPasteTriggerKey)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: hint, options: options)) ?? AttributedString(hint)
    }

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Quick paste popup") {
                ThemedToggle("Quick paste popup", isOn: $settings.quickPasteEnabled)
                    .help(Self.quickPasteHelp)
            }
            // Hidden rather than disabled while the feature is off: the window now
            // follows the height of the selected pane, so a row appearing later no
            // longer falls off the bottom edge.
            if settings.quickPasteEnabled {
                SettingsRow("Popup trigger") {
                    ThemedPopUpPicker(
                        "Popup trigger",
                        selection: $settings.quickPasteTriggerKey,
                        options: TriggerKey.allCases,
                        title: \.displayName
                    )
                    .disabled(isRecording)
                    .help(
                        isRecording
                            ? "Stop recording to change."
                            : "The recording trigger cannot be reused here."
                    )
                }
                Text(quickPasteUsageHint)
                    .font(tokens.type.fieldCaption.font)
                    .foregroundStyle(tokens.colors.secondaryText.color)
                    .lineLimit(1)
                    // One height in both themes, whatever the caption size.
                    .frame(maxWidth: .infinity, minHeight: tokens.settingsWindow.hintLineHeight, maxHeight: tokens.settingsWindow.hintLineHeight, alignment: .leading)
                SettingsRow("Popup hold") {
                    ThemedNumberField(
                        "Popup hold",
                        value: holdMilliseconds,
                        in: Self.holdMillisecondsRange,
                        step: 50,
                        unit: "ms"
                    )
                }
                SettingsRow("Popup entries") {
                    ThemedNumberField(
                        "Popup entries",
                        value: $settings.quickPasteEntryCount,
                        in: SettingsStore.quickPasteEntryCountRange,
                        step: 1,
                        unit: "entries"
                    )
                }
                SettingsRow("Clipboard history") {
                    ThemedPushButton("Clear history") {
                        coordinator.clearClipboardHistory()
                    }
                    .help("Empties the list the popup shows. The clipboard itself is left alone.")
                }
            }
        }
    }
}

private struct GeneralSettingsPane: View {
    /// How long History size must stay still before it is applied or asked about, so
    /// holding the stepper or typing a number yields one decision for the final value.
    private static let historySizeSettleNanoseconds: UInt64 = 800_000_000

    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var ownerWindow: NSWindow?
    /// What the History size field and stepper show. The setting itself changes only
    /// once the draft settles and, when that would delete entries, the user confirms (#146).
    @State private var historySizeDraft: Int
    @State private var historySizeCommitTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        _settings = ObservedObject(wrappedValue: settings)
        _historySizeDraft = State(initialValue: settings.historyMaxEntries)
    }

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Theme") {
                ThemePicker(selection: $settings.theme)
            }
            SettingsRow("Launch at login") {
                LaunchAtLoginToggle()
            }
            SettingsRow("History size") {
                ThemedNumberField(
                    "History size",
                    value: $historySizeDraft,
                    in: SettingsStore.historyMaxEntriesRange,
                    step: 1,
                    unit: "entries"
                )
            }
            SettingsRow("Usage data") {
                ThemedPushButton("Reset usage…", role: .destructive) {
                    UsageResetWindowController.show(
                        currentKey: ProviderModelKey(
                            providerID: settings.provider.rawValue,
                            modelID: coordinator.currentTranscriptionModelID
                        ),
                        parent: ownerWindow ?? SettingsWindowController.relatedWindow,
                        onReset: { keys in
                            coordinator.usageStats.resetCounters(for: keys)
                        }
                    )
                }
            }
        }
        .background {
            WindowAccessor { window in
                ownerWindow = window
            }
        }
        .onChange(of: historySizeDraft) {
            scheduleHistorySizeCommit()
        }
        .onChange(of: settings.historyMaxEntries) { _, newValue in
            historySizeDraft = newValue
        }
        .onDisappear {
            flushPendingHistorySize()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.willCloseNotification)) { _ in
            flushPendingHistorySize()
        }
    }

    private func scheduleHistorySizeCommit() {
        historySizeCommitTask?.cancel()
        historySizeCommitTask = nil
        guard historySizeDraft != settings.historyMaxEntries else { return }

        historySizeCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.historySizeSettleNanoseconds)
            guard !Task.isCancelled else { return }
            historySizeCommitTask = nil
            commitHistorySizeDraft()
        }
    }

    private func commitHistorySizeDraft() {
        switch historySizeDecision() {
        case .apply(let limit):
            applyHistorySize(limit)
        case .confirm(let prompt):
            HistorySizeConfirmation.present(prompt, from: ownerWindow) { confirmed in
                if confirmed {
                    applyHistorySize(prompt.newLimit)
                } else {
                    historySizeDraft = settings.historyMaxEntries
                }
            }
        }
    }

    /// The pane is going away with a change still settling: a change that deletes nothing
    /// is applied, one that would delete entries is dropped rather than asked about.
    private func flushPendingHistorySize() {
        guard let pending = historySizeCommitTask else { return }
        pending.cancel()
        historySizeCommitTask = nil
        if case .apply(let limit) = historySizeDecision() {
            applyHistorySize(limit)
        } else {
            historySizeDraft = settings.historyMaxEntries
        }
    }

    private func historySizeDecision() -> HistoryCapChange {
        HistoryCapChange.evaluate(
            currentLimit: settings.historyMaxEntries,
            proposedLimit: historySizeDraft,
            fileEntryCount: coordinator.history.fileEntryCount
        )
    }

    /// `AppCoordinator` forwards the setting to `HistoryStore.setMaxEntries`, which trims.
    private func applyHistorySize(_ limit: Int) {
        settings.historyMaxEntries = limit
        historySizeDraft = settings.historyMaxEntries
    }
}

/// The question asked before lowering History size deletes entries (#146).
@MainActor
enum HistorySizeConfirmation {
    /// The alert, configured but not shown, so it can also be rendered on its own.
    static func makeAlert(prompt: HistoryCapChangePrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.addButton(withTitle: HistoryCapChangePrompt.cancelButtonTitle)
        alert.buttons.first?.hasDestructiveAction = true
        // A solid red fill: the destructive flag alone draws only pale red on glass.
        alert.buttons.first?.bezelColor = .systemRed
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.dropFirst().first?.keyEquivalent = "\u{1b}"
        return alert
    }

    /// Shows the alert as a sheet on the settings window; `completion` gets true only for
    /// the delete button, and false when there is no window to show it on.
    static func present(
        _ prompt: HistoryCapChangePrompt,
        from ownerWindow: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let window: NSWindow?
        if let ownerWindow, !ownerWindow.styleMask.contains(.borderless) {
            window = ownerWindow
        } else {
            window = SettingsWindowController.relatedWindow
        }
        guard let window else {
            completion(false)
            return
        }

        makeAlert(prompt: prompt).beginSheetModal(for: window) { response in
            Task { @MainActor in
                completion(response == .alertFirstButtonReturn)
            }
        }
    }
}

private enum APIKeyValidationState: Equatable {
    case idle
    case checking
    case accepted(String)
    case rejected(String)
    case unavailable(String)

    /// What a status says about the key, which picks its colour from the theme.
    enum Tone {
        case pending
        case success
        case failure
        case caution
    }

    struct Status {
        let message: String
        let systemImage: String?
        let tone: Tone
        let helpMessage: String?
    }

    var status: Status? {
        switch self {
        case .idle:
            return nil
        case .checking:
            return Status(
                message: "Checking",
                systemImage: "clock",
                tone: .pending,
                helpMessage: "Checking API key"
            )
        case .accepted(let message):
            return Status(message: message, systemImage: nil, tone: .success, helpMessage: message)
        case .rejected(let message):
            return Status(
                message: "Invalid key",
                systemImage: "xmark.circle.fill",
                tone: .failure,
                helpMessage: message
            )
        case .unavailable(let message):
            return Status(
                message: "Not verified",
                systemImage: "exclamationmark.triangle.fill",
                tone: .caution,
                helpMessage: message
            )
        }
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// The API key's status beside its field. Classic: the status in its colour, with its
/// symbol. Midnight: grey words; Saved carries the green dot, Invalid key a dashed
/// `mutedEdge` box, and nothing is red (#105 rules 1 and 2).
private struct APIKeyValidationBadge: View {
    let status: APIKeyValidationState.Status
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        content
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .help(status.helpMessage ?? status.message)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.helpMessage ?? status.message)
    }

    @ViewBuilder private var content: some View {
        switch tokens.controls {
        case .system:
            systemContent
                .font(tokens.type.fieldCaption.font)
                .foregroundStyle(systemColor.color)
                .frame(minHeight: tokens.controlMetrics.badgeHeight, alignment: .leading)
        case .drawn:
            drawnContent
                .font(tokens.type.fieldCaption.font)
        }
    }

    @ViewBuilder private var systemContent: some View {
        if let systemImage = status.systemImage {
            Label(status.message, systemImage: systemImage)
        } else {
            Text(status.message)
        }
    }

    private var systemColor: ThemeColor {
        switch status.tone {
        case .pending: tokens.colors.secondaryText
        case .success: tokens.colors.success
        case .failure: tokens.colors.failureText
        case .caution: tokens.colors.cautionText
        }
    }

    @ViewBuilder private var drawnContent: some View {
        let metrics = tokens.controlMetrics
        switch status.tone {
        case .success:
            HStack(spacing: metrics.badgeDotGap) {
                Circle()
                    .fill(tokens.colors.success.color)
                    .frame(width: tokens.sizes.dot, height: tokens.sizes.dot)
                Text(status.message)
                    .foregroundStyle(tokens.colors.secondaryText.color)
            }
        case .failure:
            Text(status.message)
                .foregroundStyle(tokens.colors.failureText.color)
                .padding(.horizontal, metrics.badgePadding)
                .frame(height: metrics.badgeHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
                        .strokeBorder(
                            tokens.colors.mutedEdge.color,
                            style: StrokeStyle(lineWidth: metrics.edgeWidth, dash: metrics.failureDash)
                        )
                }
        case .pending:
            Text(status.message)
                .foregroundStyle(tokens.colors.secondaryText.color)
        case .caution:
            Text(status.message)
                .foregroundStyle(tokens.colors.cautionText.color)
        }
    }
}

private struct APIKeyValidationNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(result: APIKeyValidationResult) {
        switch result {
        case .accepted:
            self.title = "API key accepted"
            self.message = "The API key was validated and saved"
        case .rejected(let message):
            self.title = "Invalid API key"
            self.message = message
        case .unavailable(let message):
            self.title = "Could not verify API key"
            self.message = message
        }
    }
}

@MainActor
private enum APIKeyDeletionConfirmation {
    static func present(
        from ownerWindow: NSWindow?,
        onDelete: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Delete saved API key?"
        alert.informativeText = "This will remove the saved API key from this Mac and you will need to enter it again before using transcription"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete API Key")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.dropFirst().first?.keyEquivalent = "\u{1b}"

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onDelete()
        }

        guard let resolvedOwnerWindow = self.resolvedOwnerWindow(from: ownerWindow) else {
            return
        }

        alert.beginSheetModal(for: resolvedOwnerWindow) { response in
            Task { @MainActor in
                handleResponse(response)
            }
        }
    }

    private static func resolvedOwnerWindow(from ownerWindow: NSWindow?) -> NSWindow? {
        if let ownerWindow, !ownerWindow.styleMask.contains(.borderless) {
            return ownerWindow
        }

        return SettingsWindowController.relatedWindow
    }
}

/// The Theme row: one chip per theme — the theme's icon and its name — the selected
/// chip outlined in the brand colour (the accent colour in Classic), the others in
/// `chipEdge`. The chips fit the control height, so the row keeps the pane's rhythm.
private struct ThemePicker: View {
    @Binding var selection: AppTheme
    @Environment(\.themeTokens) private var tokens

    var body: some View {
        HStack(spacing: tokens.settingsWindow.chipSpacing) {
            ForEach(AppTheme.allCases) { theme in
                chip(for: theme)
            }
        }
    }

    private func chip(for theme: AppTheme) -> some View {
        let isSelected = theme == selection
        let window = tokens.settingsWindow

        return Button {
            selection = theme
        } label: {
            HStack(spacing: window.chipIconGap) {
                Image(Self.iconName(for: theme))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: window.chipIcon, height: window.chipIcon)
                    .accessibilityHidden(true)
                Text(theme.displayName)
                    .font(tokens.type.body.font)
                    .foregroundStyle(tokens.colors.primaryText.color)
            }
            .padding(.horizontal, window.chipPadding)
            .frame(height: tokens.sizes.control)
            .overlay {
                RoundedRectangle(cornerRadius: tokens.radii.control, style: .continuous)
                    .strokeBorder(
                        (isSelected ? tokens.colors.brand : tokens.colors.chipEdge).color,
                        lineWidth: isSelected ? window.chipSelectedOutline : tokens.controlMetrics.edgeWidth
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func iconName(for theme: AppTheme) -> String {
        switch theme {
        case .classic: "ThemeIconClassic"
        case .midnight: "ThemeIconMidnight"
        }
    }
}

/// One row: the label in `body` on the left, the control at the right text edge. The row
/// is at least `formRow` tall; the label keeps its full width and the control gets the
/// rest, so a line under a control (the Launch at login error) wraps there.
private struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.themeTokens) private var tokens

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: tokens.settingsWindow.labelSpacing) {
            Text(title)
                .font(tokens.type.body.font)
                .foregroundStyle(tokens.colors.primaryText.color)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)

            content
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: tokens.sizes.formRow, alignment: .center)
    }
}

private extension View {
    /// A glyph button at the control height, sized as the system's small controls.
    func settingsControlFrame(_ tokens: ThemeTokens) -> some View {
        controlSize(.small)
            .frame(height: tokens.sizes.control, alignment: .center)
    }
}

// MARK: - Themed Settings end

/// What the Reset usage and Usage by model windows still read from the Settings window's
/// old layout. They move onto tokens with those windows (#163, #170).
extension SettingsWindowLayout {
    static let contentPadding: CGFloat = 18
    static let backgroundColor = NSColor.controlBackgroundColor
}

private let allUsageResetKeys: [ProviderModelKey] = {
    // "whisper-1" and "distil-whisper-large-v3-en" are no longer selectable models,
    // but counters recorded under them still exist and must stay resettable.
    let openAIModelIDs = OpenAIProvider.Model.allCases.map(\.rawValue) + ["whisper-1"]
    let openai = openAIModelIDs.map {
        ProviderModelKey(providerID: TranscriptionProviderID.openai.rawValue, modelID: $0)
    }
    let groqModelIDs = GroqProvider.Model.allCases.map(\.rawValue) + ["distil-whisper-large-v3-en"]
    let groq = groqModelIDs.map {
        ProviderModelKey(providerID: TranscriptionProviderID.groq.rawValue, modelID: $0)
    }
    return openai + groq
}()

@MainActor
private enum UsageResetWindowController {
    private static var window: NSWindow?
    private static var parentWindow: NSWindow?
    private static var delegate: WindowDelegate?

    static func show(
        currentKey: ProviderModelKey,
        parent: NSWindow?,
        onReset: @escaping (Set<ProviderModelKey>) -> Void
    ) {
        let resolvedParent = resolvedParentWindow(from: parent)

        if let existing = window {
            attach(existing, to: resolvedParent)
            position(existing, over: resolvedParent)
            present(existing)
            register(existing)
            return
        }

        let content = UsageResetView(
            currentKey: currentKey,
            onReset: { keys in
                onReset(keys)
                hide()
            },
            onCancel: { hide() }
        )

        let hostingView = NSHostingView(rootView: ThemedRoot("resetUsage") { content })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reset usage"
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = SettingsWindowLayout.backgroundColor
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false

        let delegate = WindowDelegate(onClose: { closedWindow in
            windowDidClose(closedWindow)
        })
        window.delegate = delegate
        Self.delegate = delegate
        Self.window = window

        attach(window, to: resolvedParent)
        position(window, over: resolvedParent)
        present(window)
        register(window)
    }

    static func hide() {
        guard let closingWindow = window else {
            TransientWindowStack.shared.unregister(id: "usageReset")
            delegate = nil
            parentWindow = nil
            return
        }

        TransientWindowStack.shared.unregister(id: "usageReset")
        parentWindow?.removeChildWindow(closingWindow)
        closingWindow.delegate = nil
        window = nil
        parentWindow = nil
        delegate = nil
        closingWindow.close()
    }

    private static func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func resolvedParentWindow(from parent: NSWindow?) -> NSWindow? {
        if let parent, !parent.styleMask.contains(.borderless) {
            return parent
        }

        return SettingsWindowController.relatedWindow
    }

    private static func attach(_ childWindow: NSWindow, to newParent: NSWindow?) {
        if parentWindow !== newParent {
            parentWindow?.removeChildWindow(childWindow)
            parentWindow = newParent
        }

        guard let newParent,
              newParent.childWindows?.contains(where: { $0 === childWindow }) != true
        else { return }

        newParent.addChildWindow(childWindow, ordered: .above)
    }

    private static func position(_ window: NSWindow, over parent: NSWindow?) {
        guard let parent else {
            window.center()
            return
        }

        let frame = parent.frame
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private static func windowDidClose(_ closedWindow: NSWindow) {
        guard window === closedWindow else { return }

        TransientWindowStack.shared.unregister(id: "usageReset")
        parentWindow?.removeChildWindow(closedWindow)
        window = nil
        parentWindow = nil
        delegate = nil
    }

    private static func register(_ window: NSWindow) {
        TransientWindowStack.shared.register(
            id: "usageReset",
            layer: .nested,
            window: window
        ) {
            UsageResetWindowController.hide()
        }
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: (NSWindow) -> Void
        init(onClose: @escaping (NSWindow) -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }

            Task { @MainActor in self.onClose(window) }
        }
    }
}

private struct UsageResetView: View {
    let currentKey: ProviderModelKey
    let onReset: (Set<ProviderModelKey>) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<ProviderModelKey> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset usage")
                .font(.title3.weight(.semibold))
            Text("Select models to clear. This will only delete usage data - transcription history is not affected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(allKeysSelected ? "Deselect all" : "Select all") {
                    if allKeysSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(allUsageResetKeys)
                    }
                }
                .controlSize(.small)
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allUsageResetKeys, id: \.self) { key in
                        Toggle(isOn: binding(for: key)) {
                            HStack(alignment: .center, spacing: 6) {
                                Text(displayName(for: key))
                                if key == currentKey {
                                    CurrentModelBadge()
                                }
                            }
                            .frame(minHeight: 18, alignment: .center)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    onReset(selection)
                } label: {
                    Text("Reset selected")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var allKeysSelected: Bool {
        !allUsageResetKeys.isEmpty && selection.count == allUsageResetKeys.count
    }

    private func binding(for key: ProviderModelKey) -> Binding<Bool> {
        Binding(
            get: { selection.contains(key) },
            set: { include in
                if include {
                    selection.insert(key)
                } else {
                    selection.remove(key)
                }
            }
        )
    }

    private func displayName(for key: ProviderModelKey) -> String {
        let provider = TranscriptionProviderID(rawValue: key.providerID)?.displayName ?? key.providerID
        return "\(provider) · \(key.modelID)"
    }
}

private struct CurrentModelBadge: View {
    var body: some View {
        Text("Current")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 16, alignment: .center)
            .background(
                Color.secondary.opacity(0.15),
                in: Capsule()
            )
    }
}
