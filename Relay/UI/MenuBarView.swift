import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 12)
            languages
            Spacer().frame(height: 16)
            startButton
            statusLine
            notice
            tally
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(16)
        .frame(width: 300)
        .animation(.easeOut(duration: 0.2), value: appState.stats.justDiscovered)
        .onDisappear {
            // Seen it. Next time the popover opens, show the usual list.
            appState.stats.acknowledgeDiscovery()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RelayTheme.accent)
            Text("Relay")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The source row appears only when it actually needs setting. When
            // the engine detects the language there is nothing to choose, and a
            // row saying so is just noise.
            if !appState.canAutoDetect {
                RelayRow(label: "From") {
                    Picker("", selection: $appState.sourceLanguage) {
                        ForEach(Language.allCases) {
                            Text($0.displayName).tag(SourceLanguageSetting.explicit($0))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            RelayRow(label: "Translating to") {
                Picker("", selection: $appState.targetLanguage) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if appState.canAutoDetect {
                Text("Detects the spoken language automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let summary = appState.listeningSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var startButton: some View {
        Button(appState.status.isRunning ? "Stop" : "Start listening") {
            appState.toggle()
        }
        .buttonStyle(RelayPrimaryButton(running: appState.status.isRunning))
        .keyboardShortcut(.defaultAction)
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            StatusDot(colour: statusColour, pulsing: appState.status == .listening)
            Text(appState.status.friendlyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if appState.status == .listening {
                // A quiet level meter, enough to show it's hearing something.
                LevelBars(level: levelFraction)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var notice: some View {
        if let detail = appState.errorDetail {
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }

        if appState.status == .permissionRequired {
            Button("Open System Settings") { appState.openAudioSettings() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .padding(.top, 6)
        }

        if appState.status == .missingAPIKey {
            Button("Add your API key") { showSettings() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .padding(.top, 6)
        }

        if appState.status == .missingSpeechModel {
            Button("Download the speech model") { showSettings() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .padding(.top, 6)
        }
    }

    /// What Relay has done for you so far. Appears once there is something
    /// worth showing, rather than starting at a row of zeros.
    @ViewBuilder
    private var tally: some View {
        if appState.stats.hasAnything {
            Divider().padding(.top, 14)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                figure(appState.stats.wordsText, "words")
                Spacer(minLength: 8)
                figure(appState.stats.listeningText, "listening")
            }
            .padding(.top, 12)

            if let discovered = appState.stats.justDiscovered {
                // Only ever a small remark. It is the first time you have heard
                // a language through Relay, which is worth a line and nothing
                // more.
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("First time hearing \(discovered)")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RelayTheme.accent)
                .padding(.top, 6)
                .transition(.opacity)
            } else if let languages = appState.stats.languagesText {
                Text(languages)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(RelayTheme.accent)
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            footerButton("Settings") { showSettings() }
            footerButton("Recenter") { appState.resetSubtitlePosition() }
            if !appState.transcript.isEmpty {
                footerButton("Save transcript") { appState.saveTranscript() }
            }
            Spacer()
            footerButton("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
    }

    // MARK: - Derived

    private var statusColour: Color {
        switch appState.status {
        case .idle: return RelayTheme.resting
        case .connecting, .reconnecting: return RelayTheme.working
        case .listening: return RelayTheme.listening
        case .permissionRequired, .missingAPIKey, .missingSpeechModel, .error: return RelayTheme.attention
        }
    }

    /// Map RMS to a -60…0 dBFS bar so quiet speech still moves the meter.
    private var levelFraction: Float {
        let db = 20 * log10(max(appState.audioLevel, 0.000_001))
        return min(max((db + 60) / 60, 0), 1)
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let window = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}

/// Five small bars — calmer than a progress bar, and it reads as audio.
private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index + 1) / 5
                Capsule()
                    .fill(level >= threshold ? RelayTheme.listening : RelayTheme.resting.opacity(0.35))
                    .frame(width: 2.5, height: 5 + CGFloat(index) * 2)
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}
