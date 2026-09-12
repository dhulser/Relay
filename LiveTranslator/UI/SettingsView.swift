import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var apiKeyField = ""
    /// True only while the user is deliberately entering a new key. A stored
    /// key shows as stored — never as an empty box asking to be filled in.
    @State private var isEnteringKey = false

    var body: some View {
        Form {
            Section("Translation Provider") {
                Picker("Provider", selection: $appState.provider) {
                    ForEach(TranslationProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(appState.provider.pipelineDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(appState.provider.tradeOffs.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item.isAdvantage ? .green : .secondary)
                            Text(item.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 2)

                switch appState.provider {
                case .claude:
                    Picker("Model", selection: $appState.claudeModel) {
                        ForEach(ClaudeModel.allCases) { model in
                            Text("\(model.displayName) — \(model.subtitle)").tag(model)
                        }
                    }
                case .openai:
                    Picker("Model", selection: $appState.openAIModel) {
                        ForEach(OpenAITextModel.allCases) { model in
                            Text("\(model.displayName) — \(model.subtitle)").tag(model)
                        }
                    }
                case .openaiRealtime:
                    EmptyView()
                }
            }

            if appState.provider.usesLocalSpeech {
                SpeechEngineSection()
            }

            Section("\(appState.provider.credentialName) API Key") {
                if appState.hasAPIKey && !isEnteringKey {
                    LabeledContent("API Key") {
                        Label("Stored in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    HStack {
                        Button("Replace…") {
                            apiKeyField = ""
                            isEnteringKey = true
                        }
                        Button("Remove", role: .destructive) { remove() }
                        Spacer()
                    }
                } else {
                    SecureField("API Key", text: $apiKeyField,
                                prompt: Text(appState.provider.keyPlaceholder))
                        .textContentType(.password)
                        .onSubmit { save() }

                    HStack {
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if appState.hasAPIKey {
                            Button("Cancel") {
                                apiKeyField = ""
                                isEnteringKey = false
                            }
                        }
                        Spacer()
                    }
                }

                Text(keyFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Languages") {
                if appState.canAutoDetect {
                    LabeledContent("Source Language") {
                        Label("Detected automatically", systemImage: "wand.and.stars")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Source Language", selection: $appState.sourceLanguage) {
                        ForEach(Language.allCases) {
                            Text($0.displayName).tag(SourceLanguageSetting.explicit($0))
                        }
                    }
                    Text("Apple's recogniser handles one language at a time. Switch the speech "
                         + "engine to Whisper to detect it automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Target Language", selection: $appState.targetLanguage) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Language changes take effect the next time you start translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { appState.refreshAPIKeyState() }
        .onChange(of: appState.provider) { _, _ in
            // The field holds a key for the provider that was selected a moment
            // ago — clear it rather than risk saving it under the new one.
            apiKeyField = ""
            isEnteringKey = false
        }
    }

    private var keyFootnote: String {
        let shared = appState.provider.usesLocalSpeech
            ? ""
            : " The OpenAI and OpenAI Realtime providers share this key."
        return "Stored in your macOS Keychain. Never written to disk or logged by this app."
            + shared
    }

    private func save() {
        guard !apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        KeychainService.saveAPIKey(apiKeyField, for: appState.provider)
        // Never keep the key in view state longer than needed.
        apiKeyField = ""
        isEnteringKey = false
        appState.refreshAPIKeyState()
    }

    private func remove() {
        KeychainService.deleteAPIKey(for: appState.provider)
        apiKeyField = ""
        isEnteringKey = false
        appState.refreshAPIKeyState()
    }
}
