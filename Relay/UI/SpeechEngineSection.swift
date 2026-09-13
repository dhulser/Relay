import SwiftUI

/// Everything about how speech becomes text, kept below the translation
/// settings because it is the half most people never need to touch.
struct SpeechEngineSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ModelStore.whisper

    var body: some View {
        Section("Speech recognition") {
            Picker("Engine", selection: $appState.speechEngine) {
                ForEach(SpeechEngine.allCases) { Text($0.displayName).tag($0) }
            }

            Text(appState.speechEngine.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            if appState.speechEngine == .whisper {
                Picker("Quality", selection: $appState.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text("\(model.displayName) — \(model.subtitle)").tag(model)
                    }
                }
                modelStatus

                Divider().padding(.vertical, 2)

                Toggle("Filter out music and noise", isOn: $appState.useVoiceFilter)
                if appState.useVoiceFilter {
                    ModelDownloadRow(store: ModelStore.voiceActivity, model: .silero, label: "Voice filter model")
                }
                Text("Runs a small voice-activity model on each phrase first, so a soundtrack or a noisy room "
                     + "doesn't get turned into words. Worth turning on if you see captions for things nobody said.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if appState.canLabelSpeakers {
                Divider().padding(.vertical, 2)

                Toggle("Label speakers", isOn: $appState.labelSpeakers)

                if appState.labelSpeakers {
                    Picker("Voices", selection: $appState.expectedSpeakers) {
                        Text("Detect automatically").tag(0)
                        ForEach(2...6, id: \.self) { Text("\($0) people").tag($0) }
                    }
                    ModelDownloadRow(store: ModelStore.speaker, model: .campPlus, label: "Speaker model")
                }

                Text("Tags each line with the voice that said it. It can tell two voices apart, "
                     + "not who anyone is. If you know how many people are talking, saying so "
                     + "stops it inventing extra speakers.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayTheme.working)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        let model = appState.whisperModel

        if store.downloading == model {
            HStack {
                ProgressView(value: store.progress).tint(RelayTheme.accent)
                Text("\(Int(store.progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelDownload() }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        } else if store.isInstalled(model) {
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(RelayTheme.listening)
                Spacer()
                Button("Remove") { store.delete(model) }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        } else {
            HStack {
                Text("Not downloaded yet").foregroundStyle(.secondary)
                Spacer()
                Button("Download \(model.displayName)") { store.download(model) }
                    .disabled(store.downloading != nil)
            }
            .font(.system(size: 11.5))
        }
    }
}
