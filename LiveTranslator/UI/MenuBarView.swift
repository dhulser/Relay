import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

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
                Button("Open Settings") { showSettings() }
                    .frame(maxWidth: .infinity)
            }

            Button(appState.status.isRunning ? "Stop Translation" : "Start Translation") {
                appState.toggle()
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Button("Settings…") { showSettings() }
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

    /// Opens Settings *in front*. A menu-bar-only app is an accessory, so it
    /// is never the active app — without activating first, the window opens
    /// behind whatever the user was looking at.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()

        // SwiftUI creates the window after the action returns, so raise it on
        // the next pass. Panels are ours (overlay, popover); the settings
        // window is the plain NSWindow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let settingsWindow = NSApp.windows.first {
                $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain
            }
            settingsWindow?.makeKeyAndOrderFront(nil)
            settingsWindow?.orderFrontRegardless()
        }
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
