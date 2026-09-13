import SwiftUI

/// Speech-recognition settings for the two local providers: which recogniser,
/// and — for Whisper — which model, including downloading it.
struct SpeechEngineSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ModelStore.whisper

    var body: some View {
        Section("Speech Recognition") {
            Picker("Engine", selection: $appState.speechEngine) {
                ForEach(SpeechEngine.allCases) { engine in
                    Text("\(engine.displayName) — \(engine.subtitle)").tag(engine)
                }
            }

            if appState.speechEngine == .whisper {
                Picker("Model", selection: $appState.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text("\(model.displayName) — \(model.subtitle)").tag(model)
                    }
                }

                modelStatus

                Text("Models are downloaded once and stored in Application Support. "
                     + "Recognition runs entirely on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uses macOS's built-in recogniser. Downloads a language pack the first "
                     + "time you use a language, and handles one language at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.canLabelSpeakers {
                Toggle("Label speakers", isOn: $appState.labelSpeakers)

                if appState.labelSpeakers {
                    SpeakerModelRow()
                }

                Text("Identifies voices from a voiceprint and tags each line. It recognises that "
                     + "two lines share a voice, not who anyone is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        let model = appState.whisperModel

        if store.downloading == model {
            HStack {
                ProgressView(value: store.progress)
                Text("\(Int(store.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelDownload() }
            }
        } else if store.isInstalled(model) {
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove") { store.delete(model) }
                    .font(.caption)
            }
        } else {
            HStack {
                Text("Not downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download \(model.displayName)") { store.download(model) }
                    .disabled(store.downloading != nil)
            }
        }
    }
}
