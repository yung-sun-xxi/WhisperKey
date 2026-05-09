import SwiftUI
import SettingsStore
import TranscriptionProvider

struct PopoverContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusLine(state: coordinator.state)
            Divider()
            SettingsForm(settings: coordinator.settings)
            Divider()
            HStack {
                Spacer()
                Button("Quit WhisperKey") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct StatusLine: View {
    let state: AppCoordinator.AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
            Text(text)
                .font(.system(.body, design: .rounded))
        }
        .foregroundStyle(color)
    }

    private var symbolName: String {
        switch state {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var text: String {
        switch state {
        case .idle: return "Idle — tap Right Option to record"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .error(let message): return message
        }
    }

    private var color: Color {
        switch state {
        case .idle: return .primary
        case .recording: return .red
        case .transcribing: return .blue
        case .error: return .orange
        }
    }
}

private struct SettingsForm: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Text("Provider").gridColumnAlignment(.trailing)
                Picker("", selection: $settings.provider) {
                    ForEach(TranscriptionProviderID.allCases, id: \.self) { id in
                        Text(id.displayName).tag(id)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Model").gridColumnAlignment(.trailing)
                Picker("", selection: $settings.openAIModel) {
                    ForEach(OpenAIProvider.Model.allCases, id: \.self) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("API Key").gridColumnAlignment(.trailing)
                SecureField("sk-…", text: $settings.openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Language").gridColumnAlignment(.trailing)
                Picker("", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
            }
        }
    }
}
