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

        guard let closingWindow = window else { return }

        // Close instead of ordering out so SwiftUI-owned transient state is rebuilt next time.
        window = nil
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
        stopDismissMonitoring()
        if window === closedWindow {
            window = nil
        }
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

        return eventWindowIsPartOfSettingsUI(eventWindow, settingsWindow: settingsWindow)
    }

    private static func eventWindowIsPartOfSettingsUI(_ eventWindow: NSWindow, settingsWindow: NSWindow) -> Bool {
        // Local monitors can see sheet/modal button clicks before the alert action runs.
        // Treat those windows as Settings-owned so Cancel only dismisses the confirmation.
        return eventWindow === settingsWindow
            || eventWindow.parent === settingsWindow
            || eventWindow.sheetParent === settingsWindow
            || settingsWindow.childWindows?.contains(where: { $0 === eventWindow }) == true
            || settingsWindow.attachedSheet === eventWindow
            || eventWindow === NSApp.modalWindow
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

    private static func activateAppIfNeeded() {
        guard !NSApp.isActive else { return }

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
                    usageStats: coordinator.usageStats,
                    currentProviderID: coordinator.settings.provider.rawValue,
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
    @ObservedObject var usageStats: UsageStatsStore
    let currentProviderID: String
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
                Picker("", selection: $settings.usageStatsRange) {
                    ForEach(UsageStatsRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .pickerStyle(.menu)
                .fixedSize()
                .help("Choose the usage stats range")
            }

            Text(UsageLineFormatter.line(from: summary))
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

    private var summary: UsageSummary {
        usageStats.summary(
            providerID: currentProviderID,
            modelID: currentModelID,
            range: settings.usageStatsRange
        )
    }
}

enum UsageLineFormatter {
    static func line(from summary: UsageSummary) -> String {
        let words = wordsLabel(summary.wordCount)
        let time = audioDurationLabel(summary.audioDurationSeconds)
        var parts: [String] = ["\(words) words", time]
        if let cost = summary.estimatedCost, let currency = summary.currency {
            parts.append("~\(costLabel(cost, currency: currency))")
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
}

private struct SettingsWindowContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            SettingsForm(settings: coordinator.settings, isRecording: coordinator.state == .recording)
        }
        .padding(SettingsWindowLayout.contentPadding)
        .frame(width: SettingsWindowLayout.contentWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: SettingsWindowLayout.backgroundColor))
    }
}

private struct SettingsForm: View {
    @ObservedObject var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    let isRecording: Bool
    @State private var ownerWindow: NSWindow?
    @State private var apiKeyDraft = ""
    @State private var apiKeyValidationState = APIKeyValidationState.idle
    @State private var apiKeyValidationTask: Task<Void, Never>?
    @State private var apiKeyValidationNotice: APIKeyValidationNotice?
    @State private var isResetCountersPresented = false
    @FocusState private var apiKeyFieldFocused: Bool

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
                .onChange(of: apiKeyDraft) { oldValue, newValue in
                    handleAPIKeyDraftChange(oldValue: oldValue, newValue: newValue)
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
        switch settings.provider {
        case .openai:
            "sk-…"
        case .groq:
            "gsk_…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsWindowLayout.settingsRowSpacing) {
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
            SettingsRow("Usage counters") {
                HStack {
                    Spacer(minLength: 0)
                    Button("Reset Counters\u{2026}") {
                        isResetCountersPresented = true
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
        .alert(item: $apiKeyValidationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $isResetCountersPresented) {
            ResetCountersSheet(
                currentKey: ProviderModelKey(
                    providerID: settings.provider.rawValue,
                    modelID: coordinator.currentTranscriptionModelID
                ),
                onReset: { keys in
                    coordinator.usageStats.resetCounters(for: keys)
                    isResetCountersPresented = false
                },
                onCancel: { isResetCountersPresented = false }
            )
        }
        .onAppear {
            syncAPIKeyDraftWithStoredKey(resetState: true)
        }
        .onDisappear {
            apiKeyValidationTask?.cancel()
            apiKeyValidationTask = nil
        }
        .onChange(of: settings.provider) {
            syncAPIKeyDraftWithStoredKey(resetState: true)
        }
        .onChange(of: currentAPIKey) {
            guard apiKeyValidationState != .checking else { return }
            syncAPIKeyDraftWithStoredKey(resetState: false)
        }
    }

    private func handleAPIKeyDraftChange(oldValue: String, newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiKeyValidationTask?.cancel()
            apiKeyValidationTask = nil
            apiKeyValidationState = .idle
            settings.deleteAPIKey(for: settings.provider)
            return
        }

        if trimmed == currentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) {
            apiKeyValidationTask?.cancel()
            apiKeyValidationTask = nil
            apiKeyValidationState = currentAPIKey.isEmpty ? .idle : .accepted("API key saved")
            return
        }

        apiKeyValidationState = .idle
        let likelyPaste = abs(newValue.count - oldValue.count) > 3
        scheduleAPIKeyValidation(presentNotice: likelyPaste)
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
        case .acceptedWithWarning(let message):
            saveAPIKey(key, for: provider)
            apiKeyValidationState = .accepted(message)
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

    private func syncAPIKeyDraftWithStoredKey(resetState: Bool) {
        let storedKey = currentAPIKey
        guard apiKeyDraft != storedKey else {
            if resetState {
                apiKeyValidationState = storedKey.isEmpty ? .idle : .accepted("API key saved")
            }
            return
        }

        apiKeyValidationTask?.cancel()
        apiKeyValidationTask = nil
        apiKeyDraft = storedKey
        if resetState {
            apiKeyValidationState = storedKey.isEmpty ? .idle : .accepted("API key saved")
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
        case .acceptedWithWarning(let message):
            self.title = "API key saved"
            self.message = message
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

private struct ResetCountersSheet: View {
    let currentKey: ProviderModelKey
    let onReset: (Set<ProviderModelKey>) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<ProviderModelKey> = []

    private static let allKeys: [ProviderModelKey] = {
        let openai = OpenAIProvider.Model.allCases.map {
            ProviderModelKey(providerID: TranscriptionProviderID.openai.rawValue, modelID: $0.rawValue)
        }
        let groq = GroqProvider.Model.allCases.map {
            ProviderModelKey(providerID: TranscriptionProviderID.groq.rawValue, modelID: $0.rawValue)
        }
        return openai + groq
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset Usage Counters")
                .font(.title3.weight(.semibold))
            Text("Select the provider/model combinations to clear. This deletes usage data only — transcription history text is not affected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.allKeys, id: \.self) { key in
                        Toggle(isOn: binding(for: key)) {
                            HStack(spacing: 6) {
                                Text(displayName(for: key))
                                if key == currentKey {
                                    Text("Current")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Color.secondary.opacity(0.15),
                                            in: Capsule()
                                        )
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            HStack(spacing: 8) {
                Button("Select Current") {
                    selection = [currentKey]
                }
                Button("Select All") {
                    selection = Set(Self.allKeys)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onReset(selection)
                } label: {
                    Text("Reset Selected")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
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
