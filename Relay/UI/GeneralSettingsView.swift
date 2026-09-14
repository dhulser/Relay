import SwiftUI

/// The tab for how Relay behaves and looks, as opposed to what it translates.
struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var style = SubtitleStyle.shared
    @ObservedObject var updater: UpdaterService
    @State private var copiedDiagnostics = false

    var body: some View {
        Form {
            subtitlesSection
            listeningSection
            updatesSection
            supportSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Subtitles

    private var subtitlesSection: some View {
        Section("Subtitles") {
            // A live sample, styled the way the overlay is, so a slider move
            // can be judged without starting a session.
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Could we push it to Thursday instead?")
                        .font(.system(size: style.textSize * 0.6, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    if style.showOriginal {
                        Text("¿Podríamos pasarlo al jueves?")
                            .font(.system(size: style.smallSize * 0.6, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black.opacity(style.plateOpacity))
                )
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowBackground(
                LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 0.6), Color(red: 0.6, green: 0.5, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )

            LabeledContent("Text size") {
                Slider(value: $style.textSize, in: SubtitleStyle.sizeRange, step: 1)
                    .frame(width: 200)
            }
            LabeledContent("Background") {
                Slider(value: $style.plateOpacity, in: SubtitleStyle.opacityRange, step: 0.05)
                    .frame(width: 200)
            }
            Toggle("Show what was said under each line", isOn: $style.showOriginal)
            Text("The original words appear in smaller type beneath the translation. With the local engines they show up the moment they are heard, before the translation lands.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Listening

    private var listeningSection: some View {
        Section("Listening") {
            Toggle("Open Relay at login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.launchAtLogin = $0 }
            ))

            Toggle("Keyboard shortcut  \(GlobalHotKey.defaultDescription)", isOn: $appState.shortcutEnabled)
            Text("Starts and stops listening from inside any app.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Toggle("Keep a transcript while listening", isOn: $appState.keepTranscript)
                .disabled(appState.hosted.isActive && !appState.hosted.policy.allowTranscript)
            if appState.hosted.isActive && !appState.hosted.policy.allowTranscript {
                Text("\(appState.hosted.companyName ?? "Your company") has turned transcripts off.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayTheme.working)
            }
            Text("Held in memory only, until you press start again or quit. Nothing is written anywhere unless you save it.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            if !appState.transcript.isEmpty {
                HStack {
                    Text("\(appState.transcript.count) lines from the last session")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save…") { appState.saveTranscript() }
                    Button("Discard") { appState.discardTranscript() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 12.5))
            }
        }
    }

    // MARK: - Support

    private var supportSection: some View {
        Section("Support") {
            HStack {
                Button(copiedDiagnostics ? "Copied" : "Copy diagnostics") {
                    Diagnostics.copy(appState)
                    copiedDiagnostics = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDiagnostics = false }
                }
                Link("Report a problem", destination: URL(string: "https://github.com/dhulser/Relay/issues")!)
                    .font(.system(size: 12.5))
                Spacer()
            }
            Text("Copies Relay's own log from this run and the settings that matter, ready to paste into a report. It never includes anything that was said.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecks },
                set: { updater.automaticallyChecks = $0 }
            ))
            HStack {
                Text(UpdaterService.versionText)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            .font(.system(size: 12.5))
        }
    }
}
