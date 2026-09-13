import SwiftUI

/// Comparison mode: run several engines on the same audio at once, each in its
/// own column, and see which one you would rather read.
struct ComparisonSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Compare engines side by side", isOn: $appState.comparisonMode)

                Text("Every selected engine hears the same audio and gets its own column. "
                     + "Local engines share one speech recogniser, so they differ only in "
                     + "how they translate — and comparing them costs no extra recognition.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section("Engines") {
                ForEach(TranslationProvider.allCases) { candidate in
                    engineRow(candidate)
                }

                if appState.comparisonMode && appState.comparedProviders.count < 2 {
                    Label("Pick at least two to compare.", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayTheme.working)
                }
            }

            if appState.comparisonMode && appState.comparedProviders.count >= 2 {
                Section("While comparing") {
                    LabeledContent("Running") {
                        Text(appState.activeProviders.map(\.shortLabel).joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Costs") {
                        Text(appState.comparisonCostSummary)
                            .foregroundStyle(RelayTheme.working)
                    }
                    Text("You pay for every engine at once, so this is a mode you turn on to "
                         + "decide with rather than leave running.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func engineRow(_ candidate: TranslationProvider) -> some View {
        let enabled = appState.comparedProviders.contains(candidate)

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { on in
                    if on { appState.comparedProviders.insert(candidate) }
                    else { appState.comparedProviders.remove(candidate) }
                }
            )) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(colour(for: candidate))
                        .frame(width: 7, height: 7)
                    Text(candidate.displayName)
                }
            }
            .disabled(!appState.comparisonMode)

            // Each engine's own settings live beside it, so a comparison can be
            // configured without going back to the Translation tab.
            if enabled && appState.comparisonMode {
                Group {
                    switch candidate {
                    case .claude:
                        Picker("Model", selection: $appState.claudeModel) {
                            ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                        }
                    case .openai:
                        Picker("Model", selection: $appState.openAIModel) {
                            ForEach(OpenAITextModel.allCases) { Text($0.displayName).tag($0) }
                        }
                    case .openaiRealtime:
                        Text("No settings — the model translates the audio directly.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 20)

                if KeychainService.hasAPIKey(for: candidate) {
                    Label("\(candidate.credentialName) key saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayTheme.listening)
                        .padding(.leading, 20)
                } else {
                    Label("Needs a \(candidate.credentialName) key — add it in Translation",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayTheme.working)
                        .padding(.leading, 20)
                }
            }
        }
    }

    /// Matches the column colours in the overlay, so the settings and the
    /// subtitles agree about which engine is which.
    private func colour(for candidate: TranslationProvider) -> Color {
        guard let index = appState.activeProviders.firstIndex(of: candidate) else {
            return .secondary.opacity(0.4)
        }
        return SubtitleView.colour(at: index)
    }
}
