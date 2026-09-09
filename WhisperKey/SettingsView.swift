import AppKit
import AVFoundation
import SwiftUI
import HotkeyEngine
import SettingsStore
import TranscriptionProvider
import HistoryStore
import UsageStatsStore

private enum SettingsWindowLayout {
    static let contentWidth: CGFloat = 460
    static let contentPadding: CGFloat = 18
    static let settingsRowColumnSpacing: CGFloat = 12
    static let settingsRowSpacing: CGFloat = 8
    static let settingsRowHeight: CGFloat = 24
    static let settingsControlHeight: CGFloat = 22
    static let settingsActionIconSize: CGFloat = 14
    static let settingsRowLabelWidth: CGFloat = 136
    static let settingsRowContentWidth: CGFloat = 276
    static let backgroundColor = NSColor.controlBackgroundColor
    static let windowTitle = "WhisperKey Settings"
}

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
        guard window == nil else { return }

        let preparedWindow = makeWindow(coordinator: coordinator)
        window = preparedWindow
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
        window.toolbarStyle = .preference
        window.setContentSize(contentController.windowContentSize)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = SettingsWindowLayout.backgroundColor
        window.initialFirstResponder = contentController.focusParkingView
        window.center()
        window.delegate = delegate
        window.standardWindowButton(.zoomButton)?.isEnabled = false

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

/// One toolbar tab per pane, the way System Settings does it. Each pane is its own
/// hosting controller, so the state a pane owns — the API key draft above all — is not
/// rebuilt when the selection changes.
private final class SettingsContentViewController: NSTabViewController {
    let focusParkingView = FirstResponderParkingView(frame: .zero)

    private var isResizingWindow = false

    init(coordinator: AppCoordinator) {
        super.init(nibName: nil, bundle: nil)

        tabStyle = .toolbar
        transitionOptions = []

        for tab in SettingsTab.allCases {
            let paneController = NSHostingController(
                rootView: AnyView(
                    SettingsPane(tab: tab, settings: coordinator.settings)
                        .environmentObject(coordinator)
                )
            )
            // Reports the SwiftUI content height back as the pane's preferred size, which
            // is what drives the window resize below.
            paneController.sizingOptions = [.preferredContentSize]
            // A toolbar-style NSTabViewController takes the window title from the selected
            // pane's controller, and shows "Untitled" when it has none. The toolbar already
            // says which pane is showing, so every pane carries the window's own name.
            paneController.title = SettingsWindowLayout.windowTitle

            let item = NSTabViewItem(viewController: paneController)
            item.identifier = tab.identifier
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }

        selectedTabViewItemIndex = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        focusParkingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(focusParkingView)

        NSLayoutConstraint.activate([
            focusParkingView.widthAnchor.constraint(equalToConstant: 0),
            focusParkingView.heightAnchor.constraint(equalToConstant: 0),
            focusParkingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusParkingView.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)

        resizeWindowToSelectedPane()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)

        guard viewController === selectedPaneController else { return }

        resizeWindowToSelectedPane()
    }

    var windowContentSize: NSSize {
        loadViewIfNeeded()
        return contentSize(for: selectedPaneController)
    }

    private var selectedPaneController: NSViewController? {
        let index = selectedTabViewItemIndex
        guard index >= 0, index < tabViewItems.count else { return nil }

        return tabViewItems[index].viewController
    }

    private func contentSize(for paneController: NSViewController?) -> NSSize {
        guard let paneController else {
            return NSSize(width: SettingsWindowLayout.contentWidth, height: 1)
        }

        paneController.loadViewIfNeeded()
        let paneView = paneController.view
        paneView.layoutSubtreeIfNeeded()

        let preferredHeight = paneController.preferredContentSize.height
        let height = preferredHeight > 1 ? preferredHeight : paneView.fittingSize.height

        return NSSize(width: SettingsWindowLayout.contentWidth, height: ceil(height))
    }

    /// Keeps the window's top-left corner where it is: resizing from the bottom-left
    /// would walk the window up the screen on every tab switch.
    private func resizeWindowToSelectedPane() {
        guard !isResizingWindow, let window = view.window else { return }

        let size = contentSize(for: selectedPaneController)
        guard size.height > 1 else { return }

        isResizingWindow = true
        defer { isResizingWindow = false }

        let top = window.frame.maxY
        window.setContentSize(size)

        var frame = window.frame
        guard abs(frame.maxY - top) > 0.5 else { return }

        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
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
                    currentProviderID: coordinator.settings.provider.rawValue,
                    currentModelID: coordinator.currentTranscriptionModelID,
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

private struct CommandCenterHeader: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var usageStats: UsageStatsStore
    let currentProviderID: String
    let currentModelID: String
    let appState: AppCoordinator.AppState
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            UsageSummaryRow(summary: summary)

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
                Text("\(settings.provider.displayName) · \(currentModelID)")
                    .font(PopoverTypography.caption)
                    .foregroundColor(PopoverTypography.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("\(settings.provider.displayName) · \(currentModelID)")

            Spacer(minLength: 8)

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

    private var summary: UsageSummary {
        usageStats.summary(
            providerID: currentProviderID,
            modelID: currentModelID,
            range: settings.usageStatsRange
        )
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

    var body: some View {
        HStack(spacing: 0) {
            UsageMetricColumn(value: UsageLineFormatter.wordsLabel(summary.wordCount), label: "words")
            HeaderVerticalDivider()
            UsageMetricColumn(value: UsageLineFormatter.compactAudioDurationLabel(summary.audioDurationSeconds), label: "audio")
            HeaderVerticalDivider()
            UsageMetricColumn(value: costText ?? "-", label: nil)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 7))
        .help(UsageLineFormatter.line(from: summary))
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

private struct HeaderPeriodPicker: View {
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

private enum HeaderSurfaceColor {
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

/// One pane per toolbar tab, in the order the toolbar shows them.
private enum SettingsTab: CaseIterable {
    case transcription
    case recording
    case quickPaste
    case general

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

    var symbolName: String {
        switch self {
        case .transcription:
            return "waveform"
        case .recording:
            return "mic"
        case .quickPaste:
            return "list.clipboard"
        case .general:
            return "gearshape"
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

/// The chrome every pane shares: one width for all four, so the toolbar tabs do not
/// shift horizontally when the selection changes.
private struct SettingsPane: View {
    let tab: SettingsTab
    @ObservedObject var settings: SettingsStore

    var body: some View {
        paneContent
            .padding(SettingsWindowLayout.contentPadding)
            .frame(width: SettingsWindowLayout.contentWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: SettingsWindowLayout.backgroundColor))
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
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindowLayout.settingsRowSpacing) {
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

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Provider") {
                Picker("", selection: $settings.provider) {
                    ForEach(TranscriptionProviderID.allCases, id: \.self) { id in
                        Text(id.displayName).tag(id)
                    }
                }
                .labelsHidden()
                .settingsControlFrame()
            }
            SettingsRow("Model") {
                modelPicker
            }
            SettingsRow("API Key") {
                apiKeyField
            }
            SettingsRow("Language") {
                Picker("", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .settingsControlFrame()
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
            Picker("", selection: $settings.openAIModel) {
                ForEach(OpenAIProvider.Model.allCases, id: \.self) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .labelsHidden()
            .settingsControlFrame()
        case .groq:
            Picker("", selection: $settings.groqModel) {
                ForEach(GroqProvider.Model.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .settingsControlFrame()
        }
    }

    @ViewBuilder private var apiKeyField: some View {
        HStack(spacing: 6) {
            if let status = apiKeyValidationState.status {
                APIKeyValidationBadge(status: status)
            }

            Button {
                scheduleAPIKeyValidation(presentNotice: true, debounceNanoseconds: 0)
            } label: {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: SettingsWindowLayout.settingsActionIconSize, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .settingsControlFrame()
            .foregroundStyle(apiKeyValidationState.validationIconColor)
            .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKeyValidationState == .checking)
            .help("Validate and save API key")
            .accessibilityLabel("Validate and save API key")

            SecureField(apiKeyPlaceholder, text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 108)
                .settingsControlFrame()
                .focused($apiKeyFieldFocused)
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
                        .font(.system(size: SettingsWindowLayout.settingsActionIconSize, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .settingsControlFrame()
                .foregroundStyle(.red)
                .help("Delete saved API key")
                .accessibilityLabel("Delete saved API key")
            }
        }
        .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
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
                Picker("", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .labelsHidden()
                .settingsControlFrame()
                .disabled(isRecording)
                .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Mode") {
                Picker("", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .settingsControlFrame()
                .disabled(isRecording)
                .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Esc to cancel record") {
                Toggle("", isOn: $settings.escapeToCancelRecording)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .settingsControlFrame()
                    .disabled(isRecording)
                    .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Sound effects") {
                Toggle("", isOn: $settings.soundEffectsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .settingsControlFrame()
            }
            SettingsRow("Pause Apple Music while recording") {
                Toggle("", isOn: $settings.pauseAppleMusicWhileRecording)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .settingsControlFrame()
                    .help("Pauses Apple Music at the start of a recording and resumes it when the microphone stops.")
            }
        }
    }
}

private struct QuickPasteSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator

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

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Quick paste popup") {
                Toggle("", isOn: $settings.quickPasteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .settingsControlFrame()
                    .help(Self.quickPasteHelp)
            }
            // Hidden rather than disabled while the feature is off: the window now
            // follows the height of the selected pane, so a row appearing later no
            // longer falls off the bottom edge.
            if settings.quickPasteEnabled {
                SettingsRow("Popup trigger") {
                    Picker("", selection: $settings.quickPasteTriggerKey) {
                        ForEach(TriggerKey.allCases, id: \.self) { trigger in
                            Text(trigger.displayName)
                                .tag(trigger)
                        }
                    }
                    .labelsHidden()
                    .settingsControlFrame()
                    .disabled(isRecording)
                    .help(
                        isRecording
                            ? "Stop recording to change."
                            : "The recording trigger cannot be reused here."
                    )
                }
                SettingsRow("Popup hold") {
                    HStack(spacing: 6) {
                        TextField("", value: holdMilliseconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .settingsControlFrame()
                        Stepper("",
                                value: holdMilliseconds,
                                in: Self.holdMillisecondsRange,
                                step: 50)
                            .labelsHidden()
                            .settingsControlFrame()
                        Text("ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                    }
                    .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                }
                SettingsRow("Popup entries") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.quickPasteEntryCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .settingsControlFrame()
                        Stepper("",
                                value: $settings.quickPasteEntryCount,
                                in: SettingsStore.quickPasteEntryCountRange,
                                step: 1)
                            .labelsHidden()
                            .settingsControlFrame()
                        Text("entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                    }
                    .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                }
                SettingsRow("Clipboard history") {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Clear history") {
                            coordinator.clearClipboardHistory()
                        }
                        .controlSize(.small)
                        .help("Empties the list the popup shows. The clipboard itself is left alone.")
                    }
                    .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                }
            }
            Text(Self.quickPasteHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var ownerWindow: NSWindow?

    var body: some View {
        SettingsPaneStack {
            SettingsRow("Launch at login") {
                LaunchAtLoginToggle()
            }
            SettingsRow("History size") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.historyMaxEntries, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .settingsControlFrame()
                    Stepper("",
                            value: $settings.historyMaxEntries,
                            in: SettingsStore.historyMaxEntriesRange,
                            step: 1)
                        .labelsHidden()
                        .settingsControlFrame()
                    Text("entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
                }
                .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
            }
            SettingsRow("Usage stats") {
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset usage") {
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
                    .controlSize(.small)
                }
                .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
            }
        }
        .background {
            WindowAccessor { window in
                ownerWindow = window
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

    struct Status {
        let message: String
        let systemImage: String?
        let color: Color
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
                color: .secondary,
                helpMessage: "Checking API key"
            )
        case .accepted(let message):
            return Status(message: message, systemImage: nil, color: .green, helpMessage: message)
        case .rejected(let message):
            return Status(
                message: "Invalid key",
                systemImage: "xmark.circle.fill",
                color: .red,
                helpMessage: message
            )
        case .unavailable(let message):
            return Status(
                message: "Not verified",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange,
                helpMessage: message
            )
        }
    }

    var validationIconColor: Color {
        switch self {
        case .accepted:
            return .green
        default:
            return .primary
        }
    }
}

private struct APIKeyValidationBadge: View {
    let status: APIKeyValidationState.Status

    var body: some View {
        content
            .font(.caption2)
            .foregroundStyle(status.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: SettingsWindowLayout.settingsControlHeight, alignment: .leading)
            .help(status.helpMessage ?? status.message)
            .accessibilityLabel(status.helpMessage ?? status.message)
    }

    @ViewBuilder private var content: some View {
        if let systemImage = status.systemImage {
            Label(status.message, systemImage: systemImage)
        } else {
            Text(status.message)
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

private struct SettingsRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsWindowLayout.settingsRowColumnSpacing) {
            Text(title)
                .lineLimit(1)
                .frame(width: SettingsWindowLayout.settingsRowLabelWidth, alignment: .leading)
                .frame(minHeight: SettingsWindowLayout.settingsControlHeight, alignment: .center)

            content
                .controlSize(.small)
                .frame(width: SettingsWindowLayout.settingsRowContentWidth, alignment: .trailing)
                .frame(minHeight: SettingsWindowLayout.settingsControlHeight, alignment: .center)
        }
        .frame(minHeight: SettingsWindowLayout.settingsRowHeight, alignment: .center)
    }
}

private extension View {
    func settingsControlFrame() -> some View {
        controlSize(.small)
            .frame(height: SettingsWindowLayout.settingsControlHeight, alignment: .center)
    }
}

private let allUsageResetKeys: [ProviderModelKey] = {
    let openai = OpenAIProvider.Model.allCases.map {
        ProviderModelKey(providerID: TranscriptionProviderID.openai.rawValue, modelID: $0.rawValue)
    }
    let groq = GroqProvider.Model.allCases.map {
        ProviderModelKey(providerID: TranscriptionProviderID.groq.rawValue, modelID: $0.rawValue)
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

        let hostingView = NSHostingView(rootView: content)
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
