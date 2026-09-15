import SwiftUI

/// Comparison mode: run two engines on the same audio at once, each in its own
/// column, and see which one you would rather read.
///
/// The engine list only appears once the mode is on. Showing it while the mode
/// is off meant a row could read as "on" when nothing was running, which was
/// the single most confusing thing about this screen.
struct ComparisonSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Compare engines side by side", isOn: $appState.comparisonMode)

                Text("Two engines hear the same audio and each gets its own column in the "
                     + "subtitles, so you can judge speed and phrasing against each other. "
                     + "It is a mode to turn on while you decide, then turn off.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if appState.comparisonMode {
                Section("Engines to compare") {
                    ForEach(offered) { candidate in
                        engineRow(candidate)
                    }

                    if appState.comparedProviders.count < 2 {
                        Label("Pick two.", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(RelayTheme.working)
                    }
                }

                if appState.activeProviders.count > 1 {
                    Section("While comparing") {
                        LabeledContent("On screen") {
                            HStack(spacing: 10) {
                                ForEach(Array(appState.activeProviders.enumerated()), id: \.element) { index, candidate in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(SubtitleView.colour(at: index))
                                            .frame(width: 7, height: 7)
                                        Text(label(for: candidate))
                                    }
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        LabeledContent("Costs") {
                            Text(appState.comparisonCostSummary)
                                .foregroundStyle(appState.hosted.isCompany ? .secondary : RelayTheme.working)
                        }
                        if !appState.hosted.isCompany {
                            Text("Both engines run at once, so a comparison costs both at the same time.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// What can be compared. On a hosted account every local provider is the
    /// same engine behind the proxy, so only Local and Instant are offered;
    /// a company that has turned Instant off leaves nothing to compare.
    private var offered: [TranslationProvider] {
        guard appState.hosted.isActive else { return TranslationProvider.allCases }
        var list: [TranslationProvider] = [.openai]
        if appState.hosted.policy.allowInstant { list.append(.openaiRealtime) }
        return list
    }

    /// The same words the overlay puts above each column, so the settings and
    /// the subtitles agree about which engine is which.
    private func label(for candidate: TranslationProvider) -> String {
        guard appState.hosted.isActive else { return candidate.shortLabel }
        return candidate == .openaiRealtime ? "Instant" : "Local"
    }

    @ViewBuilder
    private func engineRow(_ candidate: TranslationProvider) -> some View {
        let chosen = appState.comparedProviders.contains(candidate)

        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { chosen },
                set: { on in
                    if on { appState.comparedProviders.insert(candidate) }
                    else { appState.comparedProviders.remove(candidate) }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(for: candidate))
                    Text(candidate.characteristic)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            // Each engine's own settings sit beside it, so a comparison can be
            // set up without going back to the Translation tab.
            if chosen, !appState.hosted.isActive {
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
                        EmptyView()
                    }

                    if !KeychainService.hasAPIKey(for: candidate) {
                        Label("Needs a \(candidate.credentialName) key — add it in Translation",
                              systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RelayTheme.working)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}
