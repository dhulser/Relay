import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var apiKeyField = ""
    /// True only while the user is deliberately entering a new key. A stored
    /// key shows as stored — never as an empty box asking to be filled in.
    @State private var isEnteringKey = false

    var body: some View {
        TabView {
            Form {
                translationSection
                languagesSection
            tallySection
                if appState.provider.usesLocalSpeech { SpeechEngineSection() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Translation", systemImage: "character.bubble") }

            ComparisonSettingsView()
                .tabItem { Label("Comparison", systemImage: "rectangle.split.2x1") }
        }
        // A bounded height, not fixedSize: letting the form size to its content
        // made the window taller than the screen and pushed it under the menu
        // bar. The grouped form scrolls internally when it overflows.
        .frame(width: 520, height: 560)
        .onAppear { appState.refreshAPIKeyState() }
        .onChange(of: appState.provider) { _, _ in
            // The field holds a key for the provider that was selected a moment
            // ago — clear it rather than risk saving it under the new one.
            apiKeyField = ""
            isEnteringKey = false
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        Section("Translation") {
            Picker("", selection: $appState.provider) {
                ForEach(TranslationProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.provider.pipelineDescription)
                Text(appState.provider.characteristic)
                HStack(spacing: 5) {
                    Text(appState.provider.costPerHour)
                    Text("·").foregroundStyle(.tertiary)
                    Text(appState.provider.privacyNote)
                }
                .foregroundStyle(appState.provider.usesLocalSpeech ? RelayTheme.listening : .secondary)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
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

            apiKeyRow

        }
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        if appState.hasAPIKey && !isEnteringKey {
            LabeledContent("API key") {
                HStack(spacing: 8) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(RelayTheme.listening)
                    Button("Replace") { apiKeyField = ""; isEnteringKey = true }
                        .buttonStyle(.link)
                    Button("Remove") { remove() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11.5))
            }
        } else {
            LabeledContent("API key") {
                SecureField("", text: $apiKeyField, prompt: Text(appState.provider.keyPlaceholder))
                    .textContentType(.password)
                    .onSubmit { save() }
            }
            HStack {
                Button("Save") { save() }
                    .disabled(apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if appState.hasAPIKey {
                    Button("Cancel") { apiKeyField = ""; isEnteringKey = false }
                }
                Spacer()
                Text(keyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Languages

    private var languagesSection: some View {
        Section("Languages") {
            if !appState.canAutoDetect {
                Picker("From", selection: $appState.sourceLanguage) {
                    ForEach(Language.allCases) {
                        Text($0.displayName).tag(SourceLanguageSetting.explicit($0))
                    }
                }
            }

            Picker("Translating to", selection: $appState.targetLanguage) {
                ForEach(Language.allCases) { Text($0.displayName).tag($0) }
            }

            Text(appState.canAutoDetect
                 ? "The spoken language is detected automatically, and can change mid-session."
                 : "Apple's recogniser handles one language at a time. Switch to Whisper below to detect it automatically.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tally

    private var tallySection: some View {
        Section("Your totals") {
            LabeledContent("Translated") {
                Text("\(appState.stats.wordsText) words")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Listening") {
                Text(appState.stats.listeningText)
                    .foregroundStyle(.secondary)
            }
            if let languages = appState.stats.languagesText {
                LabeledContent("Languages heard") {
                    Text(languages)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reset totals") { appState.stats.reset() }
                    .buttonStyle(.link)
                Spacer()
            }

            Text("Relay counts words and time. It never keeps what was said.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private var keyHint: String {
        appState.provider.usesLocalSpeech
            ? "Kept in your Keychain"
            : "Shared with the OpenAI provider"
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
