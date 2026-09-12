import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Translator")
                .font(.headline)

            Divider()

            LabeledContent("Source:") {
                if appState.canAutoDetect {
                    Text("Auto-detect")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("", selection: $appState.sourceLanguage) {
                        ForEach(Language.allCases) {
                            Text($0.displayName).tag(SourceLanguageSetting.explicit($0))
                        }
                    }
                    .labelsHidden()
                }
            }

            LabeledContent("Translate to:") {
                Picker("", selection: $appState.targetLanguage) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }

            LabeledContent("Audio Source:") {
                Text("All System Audio")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Engine:") {
                Text(engineDescription)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 6) {
                Text("Status:")
                Text(appState.status.displayText)
                    .foregroundStyle(statusColor)
                    .fontWeight(.medium)
            }

            if appState.status == .listening {
                LabeledContent("Audio:") {
                    ProgressView(value: Double(levelFraction))
                        .progressViewStyle(.linear)
                        .tint(.green)
                }
            }

            if let detail = appState.errorDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.status == .permissionRequired {
                Button("Open System Settings") {
                    appState.openScreenRecordingSettings()
                }
                .frame(maxWidth: .infinity)
            }

            if appState.status == .missingAPIKey {
                SettingsLink { Text("Open Settings") }
                    .frame(maxWidth: .infinity)
            }

            Button(appState.status.isRunning ? "Stop Translation" : "Start Translation") {
                appState.toggle()
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.plain)

                Button("Recenter Subtitles") { appState.resetSubtitlePosition() }
                    .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var engineDescription: String {
        switch appState.provider {
        case .claude:
            return "\(appState.speechEngine.displayName) → Claude \(appState.claudeModel.displayName)"
        case .openai:
            return "\(appState.speechEngine.displayName) → OpenAI \(appState.openAIModel.displayName)"
        case .openaiRealtime:
            return "OpenAI Realtime"
        }
    }

    /// Map RMS to a -60…0 dBFS bar so quiet speech still moves the meter.
    private var levelFraction: Float {
        let db = 20 * log10(max(appState.audioLevel, 0.000_001))
        return min(max((db + 60) / 60, 0), 1)
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: return .secondary
        case .requestingPermission, .connecting, .reconnecting: return .orange
        case .listening: return .green
        case .permissionRequired, .missingAPIKey, .error: return .red
        }
    }
}
