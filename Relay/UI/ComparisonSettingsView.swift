import SwiftUI

/// Comparison mode: put two engines side by side on the same audio and see
/// which one you would rather read.
///
/// Two pickers rather than a list of toggles, because a comparison is always
/// "this against that" — and because the pair is what decides the two columns,
/// naming them after the columns makes the screen say what it does.
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
                if offered.count < 2 {
                    Section {
                        Label("\(appState.hosted.companyName ?? "Your company") has left one engine to run, "
                              + "so there is nothing to compare it against.",
                              systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(RelayTheme.working)
                    }
                } else {
                    Section("Compare") {
                        picker(column: 0, selection: $appState.comparisonLeft)
                        picker(column: 1, selection: $appState.comparisonRight)

                        if appState.comparisonLeft == appState.comparisonRight {
                            Label("Pick two different engines.", systemImage: "exclamationmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(RelayTheme.working)
                        }
                    }

                    if appState.activeEngines.count > 1 {
                        Section {
                            LabeledContent("Costs") {
                                Text(appState.comparisonCostSummary)
                                    .foregroundStyle(appState.hosted.isCompany ? .secondary : RelayTheme.working)
                            }
                            ForEach(missingKeys, id: \.self) { name in
                                Label("Needs a \(name) key — add it in Translation",
                                      systemImage: "exclamationmark.circle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(RelayTheme.working)
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
        }
        .formStyle(.grouped)
    }

    /// One column's engine, labelled with the colour that column will be.
    private func picker(column: Int, selection: Binding<ComparisonEngine>) -> some View {
        Picker(selection: selection) {
            ForEach(offered) { engine in
                Text(label(for: engine)).tag(engine)
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(SubtitleView.colour(at: column))
                    .frame(width: 8, height: 8)
                Text(column == 0 ? "First column" : "Second column")
            }
        }
    }

    /// What can be compared. With your own keys, every model of every
    /// provider. On a hosted account the proxy decides the model — the
    /// company's admin chose it — so the choice is Local against Instant.
    private var offered: [ComparisonEngine] {
        guard appState.hosted.isActive else { return ComparisonEngine.all }

        var list: [ComparisonEngine] = []
        if appState.hosted.allowsModelChoice {
            // Only models the company has given Relay a key for.
            if appState.hosted.orgProviders.contains(.claude) {
                list += ClaudeModel.allCases.map(ComparisonEngine.claude)
            }
            if appState.hosted.orgProviders.contains(.openai) {
                list += OpenAITextModel.allCases.map(ComparisonEngine.openai)
            }
        } else {
            list.append(.openai(appState.openAIModel))
        }
        if appState.hosted.policy.allowInstant, appState.hosted.orgProviders.contains(.openaiRealtime) {
            list.append(.instant)
        }
        return list.isEmpty ? [.openai(appState.openAIModel)] : list
    }

    private func label(for engine: ComparisonEngine) -> String {
        guard appState.hosted.isActive else { return engine.shortLabel }
        if engine.isInstant { return "Instant" }
        // With a choice of models, name the one being run; without, the
        // column is just "Local" whatever the proxy happens to use.
        return appState.hosted.allowsModelChoice ? engine.shortLabel : "Local"
    }

    /// Providers in the comparison with no key saved, named once each.
    private var missingKeys: [String] {
        guard !appState.hosted.isActive else { return [] }
        var seen: Set<String> = []
        return appState.activeEngines
            .map(\.provider)
            .filter { !KeychainService.hasAPIKey(for: $0) }
            .map(\.credentialName)
            .filter { seen.insert($0).inserted }
    }
}
