import AppKit
import Foundation
import OSLog

/// A support report someone can paste: versions, the settings that matter,
/// and Relay's own log from this run. Never what was said: spoken and
/// translated text is logged at debug level and is left out here.
@MainActor
enum Diagnostics {

    static func copy(_ appState: AppState) {
        let text = report(appState)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.info(.app, "Diagnostics copied (\(text.count) characters)")
    }

    static func report(_ appState: AppState) -> String {
        var lines: [String] = []
        lines.append("Relay diagnostics")
        lines.append(UpdaterService.versionText)
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(hardware())")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("Status: \(appState.status.friendlyText)")
        if let detail = appState.errorDetail { lines.append("Notice: \(detail)") }
        if let warning = appState.warning { lines.append("Warning: \(warning)") }
        lines.append("")

        lines.append("Listen to: \(appState.audioSource.displayName)")
        if appState.audioSource == .apps {
            lines.append("Chosen apps: \(appState.chosenApps.sorted().joined(separator: ", "))")
            let open = ListenableApp.running.filter { appState.chosenApps.contains($0.bundleID) }.map(\.name)
            lines.append("Chosen apps open now: \(open.isEmpty ? "none" : open.joined(separator: ", "))")
        }
        lines.append("Engine: \(appState.provider.displayName)"
                     + (appState.comparisonMode ? " (comparison: \(appState.activeEngines.map(\.shortLabel).joined(separator: " vs ")))" : ""))
        switch appState.provider {
        case .claude: lines.append("Model: \(appState.claudeModel.displayName)")
        case .openai: lines.append("Model: \(appState.openAIModel.displayName)")
        case .openaiRealtime: break
        }
        lines.append("Relay Hosted: \(appState.hosted.isActive ? "on" : appState.hosted.isSignedIn ? "signed in, off" : "not signed in")")
        lines.append("Anthropic key stored: \(KeychainService.hasAPIKey(for: .claude) ? "yes" : "no")")
        lines.append("OpenAI key stored: \(KeychainService.hasAPIKey(for: .openai) ? "yes" : "no")")
        lines.append("Speech engine: \(appState.speechEngine.displayName)")
        if appState.speechEngine == .whisper {
            lines.append("Whisper model: \(appState.whisperModel.displayName), "
                         + (ModelStore.whisper.isInstalled(appState.whisperModel) ? "downloaded" : "NOT downloaded"))
        }
        lines.append("Speaker labels: \(appState.labelSpeakers ? "on" : "off")"
                     + (appState.labelSpeakers ? ", model \(ModelStore.speaker.isInstalled(.campPlus) ? "downloaded" : "NOT downloaded")" : ""))
        lines.append("Voice filter: \(appState.useVoiceFilter ? "on" : "off")"
                     + (appState.useVoiceFilter ? ", model \(ModelStore.voiceActivity.isInstalled(.silero) ? "downloaded" : "NOT downloaded")" : ""))
        lines.append("Languages: \(appState.sourceLanguage.displayName) → \(appState.targetLanguage.displayName)")
        lines.append("Show original: \(SubtitleStyle.shared.showOriginal ? "on" : "off")")
        lines.append("")

        lines.append("Log, last 15 minutes of this run (no transcript content):")
        lines.append(recentLog(minutes: 15))
        return lines.joined(separator: "\n")
    }

    /// Relay's own entries from the unified log, this process only.
    static func recentLog(minutes: Int) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(timeIntervalSinceEnd: -Double(minutes * 60))
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss.SSS"

            var lines: [String] = []
            for entry in try store.getEntries(at: position) {
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem == "co.kevel.Relay",
                      log.level != .debug   // where spoken text lives; never included
                else { continue }
                let level = log.level == .error || log.level == .fault ? " ERROR" : ""
                lines.append("\(clock.string(from: log.date)) [\(log.category)]\(level) \(log.composedMessage)")
            }
            return lines.isEmpty ? "(nothing logged yet)" : lines.suffix(400).joined(separator: "\n")
        } catch {
            return "Could not read the log: \(error.localizedDescription)"
        }
    }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
