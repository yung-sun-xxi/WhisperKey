import AppKit
import AVFoundation
import SwiftUI
import HotkeyEngine
import SettingsStore
import TranscriptionProvider
import HistoryStore

private enum SettingsWindowLayout {
    static let contentWidth: CGFloat = 460
    static let backgroundColor = NSColor.controlBackgroundColor
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static let delegate = SettingsWindowDelegate()
    private static var localMouseMonitor: Any?
    private static var globalMouseMonitor: Any?

    static var relatedWindow: NSWindow? {
        window
    }

    static func prepare(coordinator: AppCoordinator) {
        guard window == nil else { return }

        let preparedWindow = makeWindow(coordinator: coordinator)
        window = preparedWindow
    }

    static func hide() {
        stopDismissMonitoring()

        guard let window else { return }

        window.orderOut(nil)
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

    static func windowDidClose() {
        stopDismissMonitoring()
        window = nil
    }

    private static func makeWindow(coordinator: AppCoordinator) -> NSWindow {
        let contentController = SettingsContentViewController(
            rootView: AnyView(
                SettingsWindowContent(coordinator: coordinator)
                .environmentObject(coordinator)
            )
        )

        let window = SettingsWindow(contentViewController: contentController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "WhisperKey Settings"
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
        activateAppIfNeeded()
        window.makeKeyAndOrderFront(nil)
        focusParkingView(in: window)
        startDismissMonitoring()

        DispatchQueue.main.async { [weak window] in
            guard let window else { return }

            focusParkingView(in: window)
        }
    }

    private static func startDismissMonitoring() {
        stopDismissMonitoring()

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard !eventIsInsideSettingsWindow(event) else { return event }

            SettingsWindowController.hide()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                SettingsWindowController.hide()
            }
        }
    }

    private static func stopDismissMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private static func eventIsInsideSettingsWindow(_ event: NSEvent) -> Bool {
        guard let settingsWindow = window,
              let eventWindow = event.window
        else { return false }

        return eventWindow === settingsWindow
            || eventWindow.parent === settingsWindow
            || settingsWindow.childWindows?.contains(where: { $0 === eventWindow }) == true
    }

    private static func focusParkingView(in window: NSWindow) {
        guard let initialFirstResponder = window.initialFirstResponder else {
            window.makeFirstResponder(nil)
            return
        }

        window.makeFirstResponder(initialFirstResponder)
    }

    private static func activateAppIfNeeded() {
        guard !NSApp.isActive else { return }

        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            SettingsWindowController.windowDidClose()
        }
    }
}

private final class SettingsContentViewController: NSViewController {
    let focusParkingView = FirstResponderParkingView(frame: .zero)

    private let hostingController: NSHostingController<AnyView>

    init(rootView: AnyView) {
        self.hostingController = NSHostingController(rootView: rootView)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)

        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        focusParkingView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hostedView)
        view.addSubview(focusParkingView)

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            focusParkingView.widthAnchor.constraint(equalToConstant: 0),
            focusParkingView.heightAnchor.constraint(equalToConstant: 0),
            focusParkingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusParkingView.topAnchor.constraint(equalTo: view.topAnchor),
        ])
    }

    var windowContentSize: NSSize {
        view.layoutSubtreeIfNeeded()
        hostingController.view.layoutSubtreeIfNeeded()

        let fittingSize = hostingController.view.fittingSize
        return NSSize(
            width: SettingsWindowLayout.contentWidth,
            height: ceil(fittingSize.height)
        )
    }
}

private final class SettingsWindow: NSWindow {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let banner = PermissionBanner(coordinator: coordinator) {
                    banner
                }
                CommandCenterHeader(
                    settings: coordinator.settings,
                    history: coordinator.history,
                    currentModelID: coordinator.currentTranscriptionModelID
                )
                Divider()
                HistorySection(history: coordinator.history)
                Divider()
                HStack {
                    Button("Settings") {
                        coordinator.openSettingsWindow()
                    }
                    .keyboardShortcut(",", modifiers: [.command])
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .padding(14)
        }
        .frame(width: MenuBarLayout.popoverWidth)
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
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
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
    @ObservedObject var history: HistoryStore
    let currentModelID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("\(settings.provider.displayName) · \(currentModelID)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(settings.provider.displayName) · \(currentModelID)")
                Spacer(minLength: 0)
            }

            Text(usageLine)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 10) {
                Toggle("Clipboard", isOn: $settings.saveTranscriptionToClipboard)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("Auto-paste", isOn: $settings.autoPasteTranscription)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .font(.system(.callout))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: HistoryUsageSummary {
        history.usageSummaryForToday()
    }

    private var usageLine: String {
        if let estimatedCost = summary.estimatedCost, let currency = summary.currency {
            return "\(wordsLabel(summary.wordCount)) words today (~\(costLabel(estimatedCost, currency: currency)))"
        }
        return "\(wordsLabel(summary.wordCount)) words today"
    }

    private func wordsLabel(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let value = Double(count) / 1_000
        return String(format: value >= 10 ? "%.0fk" : "%.1fk", value)
    }

    private func costLabel(_ amount: Double, currency: String) -> String {
        switch currency.uppercased() {
        case "USD":
            return String(format: "$%.2f", amount)
        default:
            return String(format: "%.2f %@", amount, currency.uppercased())
        }
    }
}

private struct SettingsWindowContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            SettingsForm(settings: coordinator.settings, isRecording: coordinator.state == .recording)
        }
        .padding(18)
        .frame(width: SettingsWindowLayout.contentWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: SettingsWindowLayout.backgroundColor))
    }
}

private struct SettingsForm: View {
    @ObservedObject var settings: SettingsStore
    let isRecording: Bool

    @ViewBuilder private var modelPicker: some View {
        switch settings.provider {
        case .openai:
            Picker("", selection: $settings.openAIModel) {
                ForEach(OpenAIProvider.Model.allCases, id: \.self) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .labelsHidden()
        case .groq:
            Picker("", selection: $settings.groqModel) {
                ForEach(GroqProvider.Model.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder private var apiKeyField: some View {
        switch settings.provider {
        case .openai:
            SecureField("sk-…", text: $settings.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
        case .groq:
            SecureField("gsk_…", text: $settings.groqAPIKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow("Provider") {
                Picker("", selection: $settings.provider) {
                    ForEach(TranscriptionProviderID.allCases, id: \.self) { id in
                        Text(id.displayName).tag(id)
                    }
                }
                .labelsHidden()
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
            }
            SettingsRow("Trigger") {
                Picker("", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .labelsHidden()
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
                .disabled(isRecording)
                .help(isRecording ? "Stop recording to change." : "")
            }
            SettingsRow("Sound effects") {
                Toggle("", isOn: $settings.soundEffectsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow("Launch at login") {
                LaunchAtLoginToggle()
            }
            SettingsRow("History size") {
                HStack(spacing: 6) {
                    TextField("", value: $settings.historyMaxEntries, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Stepper("",
                            value: $settings.historyMaxEntries,
                            in: SettingsStore.historyMaxEntriesRange,
                            step: 1)
                        .labelsHidden()
                    Text("entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(width: 230, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}
