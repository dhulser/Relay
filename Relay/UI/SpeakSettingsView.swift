import SwiftUI

/// The tab for Speak: talking back through Relay in the other person's language.
struct SpeakSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var hasOpenAIKey: Bool { KeychainService.loadAPIKey(for: .openai) != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Speak for me", isOn: $appState.speakEnabled)
                Text("While Relay is listening, hold \(AppState.speakKeyDescription), say something in \(appState.targetLanguage.displayName), and let go. The other person hears it in their language, in a synthetic voice, through this Mac's speakers. Your line appears in the subtitles marked You.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker("Voice", selection: $appState.speakVoice) {
                    ForEach(SpeakVoice.allCases) { Text("\($0.displayName) · \($0.detail)").tag($0) }
                }
                if hasOpenAIKey {
                    Text("OpenAI's voice, on your OpenAI key: about a cent and a half per minute of speech. If it fails mid-call, the Mac's own voice fills in.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Without an OpenAI key, Relay uses the Mac's built-in voice, which sounds noticeably robotic. Add a key under Translation for the natural voices.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Languages") {
                LabeledContent("You speak") {
                    Text(appState.targetLanguage.displayName)
                        .foregroundStyle(.secondary)
                }
                Text("The language your subtitles are translated into. Change it in the popover.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Picker("Speak to them in", selection: $appState.speakTo) {
                    Text("Whatever they last spoke").tag(SourceLanguageSetting.auto)
                    Divider()
                    ForEach(Language.allCases) { Text($0.displayName).tag(SourceLanguageSetting.explicit($0)) }
                }
                Text("With the automatic setting, Relay replies in the language of the last thing it heard from them, so you may need to let them speak first.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Key") {
                Toggle("Press once to start, again to stop", isOn: $appState.speakToggleMode)
                Text("Otherwise hold \(AppState.speakKeyDescription) while you talk. Pressing it while Relay is speaking cuts the speech off. The popover has a hold-to-talk button as well.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("The microphone is opened for the session and listened to only while the key is down. What you say is recognised on this Mac; the text goes to your translation provider and, for the natural voices, to OpenAI. Nothing is stored.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
