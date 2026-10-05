import SwiftUI

/// The tab for Speak: talking back through Relay in the other person's language.
struct SpeakSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var hasOpenAIKey: Bool { KeychainService.loadAPIKey(for: .openai) != nil }

    var body: some View {
        Form {
            Section {
                Toggle("Speak for me", isOn: $appState.speakEnabled)
                Text("While Relay is listening, hold \(AppState.speakKeyDescription), say something in \(appState.targetLanguage.displayName), and let go. The other person hears it in their language, in a synthetic voice. Your line appears in the subtitles marked You.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Where the voice goes") {
                Picker("", selection: $appState.speakOutput) {
                    ForEach(SpeakOutput.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(appState.speakOutput.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if appState.speakOutput == .call {
                    if appState.audioSource == .microphone {
                        Text("Relay is listening to the microphone, which means the other person is in the room with you, so the voice goes to the speakers for now. Choose a different source under Translation to speak into a call.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    } else {
                        CallLineStatus(speak: appState.speak)
                        Toggle("Also play it on this Mac", isOn: $appState.speakMonitor)
                        Toggle("Let them hear my own voice too, while I talk", isOn: $appState.speakHearOriginal)
                        Text("Between translations your real microphone passes straight through Relay Voice, so you can still just talk. Wear headphones, or the call hears itself through your microphone.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Before speaking") {
                Toggle("Show me the translation first", isOn: $appState.speakConfirm)
                Text("The translation waits on screen. Tap the key to say it, or hold the key to say something else instead. The popover has Say it and Drop it buttons too.")
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
                Text("In the room, the microphone is opened for the session and listened to only while the key is down. On a call it stays open while Speak is on, so Relay Voice can carry your voice between translations; those buffers are copied, never recognised or sent anywhere. What you say with the key down is recognised on this Mac; the text goes to your translation provider and, for the natural voices, to OpenAI. Nothing is stored.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// Whether Relay Voice exists and whether a call app has picked it.
private struct CallLineStatus: View {
    @ObservedObject var speak: SpokenReplyController

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(speak.callAppIsUsingDevice == true ? Color.green : (speak.callLineUp ? Color.orange : Color.gray))
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        guard speak.callLineUp else { return "Setting up Relay Voice…" }
        return speak.callAppIsUsingDevice == true
            ? "A call app is using Relay Voice as its microphone."
            : "Relay Voice is ready. Pick it as the microphone in Zoom, Meet, Teams or FaceTime."
    }
}
