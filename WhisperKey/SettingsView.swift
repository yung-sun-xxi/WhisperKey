import AVFoundation
import SwiftUI
import HotkeyEngine
import SettingsStore
import TranscriptionProvider
import HistoryStore

struct PopoverContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader()
            VStack(alignment: .leading, spacing: 12) {
                if let banner = PermissionBanner(coordinator: coordinator) {
                    banner
                }
                Divider()
                SectionHeader("Settings")
                SettingsForm(settings: coordinator.settings, isRecording: coordinator.state == .recording)
                Divider()
                HistorySection(history: coordinator.history)
                Divider()
                HStack {
                    Spacer()
                    Button("Quit WhisperKey") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
            .padding(16)
        }
        .frame(width: 360)
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PopoverHeader: View {
    var body: some View {
        Image("HeaderBanner")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
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
                .frame(width: 190, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}
