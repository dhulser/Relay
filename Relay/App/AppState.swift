import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

/// Languages offered in the source/target pickers, alphabetical by name.
///
/// Every one of these is in Whisper's set and accepted by the Realtime
/// translations endpoint. Apple's recogniser supports fewer; it checks at
/// start and says which it can do.
enum Language: String, CaseIterable, Identifiable, Codable {
    case arabic
    case bengali
    case catalan
    case chinese
    case czech
    case danish
    case dutch
    case english
    case filipino
    case finnish
    case french
    case german
    case greek
    case hebrew
    case hindi
    case hungarian
    case indonesian
    case italian
    case japanese
    case korean
    case malay
    case norwegian
    case persian
    case polish
    case portuguese
    case romanian
    case russian
    case spanish
    case swedish
    case tamil
    case thai
    case turkish
    case ukrainian
    case vietnamese

    var id: String { rawValue }

    /// ISO-639-1, used for the OpenAI language fields and to build the `Locale`
    /// for on-device speech recognition.
    var isoCode: String {
        switch self {
        case .arabic: return "ar"
        case .bengali: return "bn"
        case .catalan: return "ca"
        case .chinese: return "zh"
        case .czech: return "cs"
        case .danish: return "da"
        case .dutch: return "nl"
        case .english: return "en"
        case .filipino: return "tl"
        case .finnish: return "fi"
        case .french: return "fr"
        case .german: return "de"
        case .greek: return "el"
        case .hebrew: return "he"
        case .hindi: return "hi"
        case .hungarian: return "hu"
        case .indonesian: return "id"
        case .italian: return "it"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .malay: return "ms"
        case .norwegian: return "no"
        case .persian: return "fa"
        case .polish: return "pl"
        case .portuguese: return "pt"
        case .romanian: return "ro"
        case .russian: return "ru"
        case .spanish: return "es"
        case .swedish: return "sv"
        case .tamil: return "ta"
        case .thai: return "th"
        case .turkish: return "tr"
        case .ukrainian: return "uk"
        case .vietnamese: return "vi"
        }
    }

    var displayName: String {
        switch self {
        case .arabic: return "Arabic"
        case .bengali: return "Bengali"
        case .catalan: return "Catalan"
        case .chinese: return "Chinese"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .filipino: return "Filipino"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .malay: return "Malay"
        case .norwegian: return "Norwegian"
        case .persian: return "Persian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .swedish: return "Swedish"
        case .tamil: return "Tamil"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .vietnamese: return "Vietnamese"
        }
    }
}

enum SessionStatus: Equatable {
    case idle
    case connecting
    case listening
    case reconnecting
    case permissionRequired
    case missingAPIKey
    case missingSpeechModel
    case error(String)

    /// Plain language, lower case, no warning glyphs — the status dot already
    /// carries the severity, so the words can just say what is happening.
    var friendlyText: String {
        switch self {
        case .idle: return "Ready when you are"
        case .connecting: return "Warming up…"
        case .listening: return "Listening"
        case .reconnecting: return "Reconnecting…"
        case .permissionRequired: return "Needs permission to hear your Mac"
        case .missingAPIKey: return "Needs an API key"
        case .missingSpeechModel: return "Needs the speech model"
        case .error: return "Something went wrong"
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .permissionRequired, .missingAPIKey, .missingSpeechModel, .error: return false
        case .connecting, .listening, .reconnecting: return true
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: SessionStatus = .idle
    @Published var errorDetail: String?

    /// 0…1 peak level of the captured system audio, for the popover meter.
    @Published var audioLevel: Float = 0

    /// Whether the *selected* provider has a key stored.
    @Published var hasAPIKey = false

    @Published var provider: TranslationProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: Self.providerKey)
            reconcileSourceLanguage()
            refreshReadiness()
        }
    }
    @Published var claudeModel: ClaudeModel {
        didSet { defaults.set(claudeModel.rawValue, forKey: Self.modelKey) }
    }
    @Published var openAIModel: OpenAITextModel {
        didSet { defaults.set(openAIModel.rawValue, forKey: Self.openAIModelKey) }
    }
    @Published var speechEngine: SpeechEngine {
        didSet {
            defaults.set(speechEngine.rawValue, forKey: Self.speechEngineKey)
            reconcileSourceLanguage()
            refreshReadiness()
        }
    }
    @Published var whisperModel: WhisperModel {
        didSet {
            defaults.set(whisperModel.rawValue, forKey: Self.whisperModelKey)
            refreshReadiness()
        }
    }

    /// Voiceprint speaker labelling. Only possible on the local pipelines,
    /// where we hold the audio that produced each line.
    @Published var labelSpeakers: Bool {
        didSet { defaults.set(labelSpeakers, forKey: Self.labelSpeakersKey) }
    }

    /// Whether speaker labelling can run at all with the current selection.
    var canLabelSpeakers: Bool {
        provider.usesLocalSpeech && speechEngine == .whisper
    }

    /// Run several engines on the same audio at once, each in its own column.
    /// Costs every selected engine at the same time, so it is a thing you turn
    /// on to decide with, not to leave on.
    @Published var comparisonMode: Bool {
        didSet { defaults.set(comparisonMode, forKey: Self.compareKey) }
    }

    /// Which engines a comparison runs. Two or more for the mode to do anything.
    @Published var comparedProviders: Set<TranslationProvider> {
        didSet {
            defaults.set(comparedProviders.map(\.rawValue), forKey: Self.comparedKey)
        }
    }

    /// Combined hourly cost of everything a comparison would run.
    var comparisonCostSummary: String {
        let running = activeProviders
        guard running.count > 1 else { return "" }
        return running.map(\.costPerHour).joined(separator: " + ")
    }

    /// How many distinct voices to allow. 0 means "work it out", which is right
    /// for unknown content but will occasionally over-split; naming the real
    /// number makes extra speakers impossible.
    @Published var expectedSpeakers: Int {
        didSet { defaults.set(expectedSpeakers, forKey: Self.expectedSpeakersKey) }
    }

    /// Auto-detect is possible when the Realtime model is doing the listening,
    /// or when the local recogniser is Whisper.
    var canAutoDetect: Bool {
        provider.usesLocalSpeech ? speechEngine.detectsLanguage : true
    }
    @Published var sourceLanguage: SourceLanguageSetting {
        didSet {
            defaults.set(sourceLanguage.storageValue, forKey: Self.sourceKey)
            // Remembered so the Claude engine has something concrete to use
            // when the setting is Auto-detect.
            if let explicit = sourceLanguage.language {
                lastExplicitSource = explicit
                defaults.set(explicit.rawValue, forKey: Self.lastExplicitSourceKey)
            }
        }
    }

    /// Keeps `sourceLanguage` consistent with what the selected engine can do.
    ///
    /// This runs in both directions on purpose. An engine that detects the
    /// language is forced to `.auto`, because otherwise a language stored from
    /// an earlier session would stay in effect with no control showing it —
    /// silently pinning Whisper to one language. An engine that can't detect is
    /// forced back to the last explicit choice.
    private func reconcileSourceLanguage() {
        if canAutoDetect {
            if sourceLanguage != .auto { sourceLanguage = .auto }
        } else if sourceLanguage == .auto {
            sourceLanguage = .explicit(lastExplicitSource)
        }
    }

    private var lastExplicitSource: Language
    @Published var targetLanguage: Language {
        didSet { defaults.set(targetLanguage.rawValue, forKey: Self.targetKey) }
    }

    /// Where the audio comes from: everything, chosen apps, or the microphone.
    @Published var audioSource: AudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Self.audioSourceKey) }
    }
    /// Bundle identifiers of the apps to hear when `audioSource` is `.apps`.
    @Published var chosenApps: Set<String> {
        didSet { defaults.set(Array(chosenApps).sorted(), forKey: Self.chosenAppsKey) }
    }
    /// Run Silero VAD inside Whisper to drop music and noise from each phrase.
    @Published var useVoiceFilter: Bool {
        didSet { defaults.set(useVoiceFilter, forKey: Self.voiceFilterKey) }
    }

    /// Keep every finished line in memory while listening, so it can be saved.
    /// Off by default: Relay's promise is that it keeps nothing unless asked.
    @Published var keepTranscript: Bool {
        didSet { defaults.set(keepTranscript, forKey: Self.keepTranscriptKey) }
    }
    /// The current transcript. Memory only; replaced at the next Start and
    /// gone at quit, unless saved.
    @Published private(set) var transcript: [TranscriptEntry] = []

    /// ⌃⌥⌘R from any app.
    @Published var shortcutEnabled: Bool {
        didSet {
            defaults.set(shortcutEnabled, forKey: Self.shortcutKey)
            applyShortcut()
        }
    }
    private var hotKey: GlobalHotKey?

    /// Registered with launchd through SMAppService; macOS owns the truth, so
    /// this reads it back rather than storing its own copy.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error(.app, "Launch at login: \(error.localizedDescription)")
            }
        }
    }

    let updater = UpdaterService()
    /// Relay Hosted: when active, Local and Instant go through the Relay API
    /// with the account token instead of the user's own provider keys.
    let hosted = HostedAccount()

    private let defaults = UserDefaults.standard
    private static let keepTranscriptKey = "keepTranscript"
    private static let audioSourceKey = "audioSource"
    private static let chosenAppsKey = "chosenAppBundleIDs"
    private static let voiceFilterKey = "voiceActivityFilter"
    private static let shortcutKey = "globalShortcut"
    private static let providerKey = "translationProvider"
    private static let modelKey = "claudeModel"
    private static let openAIModelKey = "openAIModel"
    private static let speechEngineKey = "speechEngine"
    private static let whisperModelKey = "whisperModel"
    private static let labelSpeakersKey = "labelSpeakers"
    private static let expectedSpeakersKey = "expectedSpeakers"
    private static let compareKey = "comparisonMode"
    private static let comparedKey = "comparedProviders"
    private static let sourceKey = "sourceLanguage"
    private static let lastExplicitSourceKey = "lastExplicitSourceLanguage"
    private static let targetKey = "targetLanguage"

    private let systemCapture = SystemAudioCaptureService()
    private let microphoneCapture = MicrophoneCaptureService()
    /// Whichever source the running session uses.
    private var capture: AudioCapturing?
    private var lanes: [Lane] = []

    /// One recogniser shared by every local translator in the session.
    private var sharedTranscriber: SpeechTranscribing?

    let stats = TranslationStats()

    private lazy var subtitlePanel = SubtitlePanelController()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: Self.providerKey).flatMap(TranslationProvider.init) ?? .claude
        claudeModel = defaults.string(forKey: Self.modelKey).flatMap(ClaudeModel.init) ?? .haiku45
        openAIModel = defaults.string(forKey: Self.openAIModelKey).flatMap(OpenAITextModel.init) ?? .luna
        speechEngine = defaults.string(forKey: Self.speechEngineKey).flatMap(SpeechEngine.init) ?? .whisper
        whisperModel = defaults.string(forKey: Self.whisperModelKey).flatMap(WhisperModel.init) ?? .small
        labelSpeakers = defaults.bool(forKey: Self.labelSpeakersKey)
        expectedSpeakers = defaults.integer(forKey: Self.expectedSpeakersKey)
        comparisonMode = defaults.bool(forKey: Self.compareKey)
        let storedCompared = defaults.stringArray(forKey: Self.comparedKey) ?? []
        let restored = Set(storedCompared.compactMap(TranslationProvider.init))
        comparedProviders = restored.isEmpty ? [.claude, .openaiRealtime] : restored
        sourceLanguage = SourceLanguageSetting(storageValue: defaults.string(forKey: Self.sourceKey) ?? "auto")
        lastExplicitSource = defaults.string(forKey: Self.lastExplicitSourceKey).flatMap(Language.init) ?? .spanish
        targetLanguage = defaults.string(forKey: Self.targetKey).flatMap(Language.init) ?? .english
        keepTranscript = defaults.bool(forKey: Self.keepTranscriptKey)
        shortcutEnabled = defaults.object(forKey: Self.shortcutKey) as? Bool ?? true
        audioSource = defaults.string(forKey: Self.audioSourceKey).flatMap(AudioSource.init) ?? .systemAudio
        chosenApps = Set(defaults.stringArray(forKey: Self.chosenAppsKey) ?? [])
        useVoiceFilter = defaults.bool(forKey: Self.voiceFilterKey)

        attach(systemCapture)
        attach(microphoneCapture)

        // A model finishing its download should turn "Needs the speech model"
        // into "Ready" without anyone reopening Settings.
        ModelStore.whisper.$installed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshReadiness() }
            .store(in: &cancellables)

        // Hosted signing in or out changes what "ready" means.
        hosted.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refreshReadiness()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AppDelegate.activationNotification)
            .compactMap { $0.userInfo?["token"] as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] token in
                guard let self else { return }
                Task {
                    await self.hosted.activate(token: token)
                    self.refreshReadiness()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .store(in: &cancellables)

        reconcileSourceLanguage()
        refreshReadiness()
        applyShortcut()
        Log.info(.app, "whisper.cpp \(WhisperRuntime.version), "
            + "\(WhisperRuntime.languageCount) languages; "
            + "sherpa-onnx \(SpeakerRuntime.version)")
    }

    private func attach(_ source: AudioCapturing) {
        source.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.audioLevel = level }
        }
        source.onError = { [weak self] error in
            MainActor.assumeIsolated { self?.fail(with: error.localizedDescription, kind: error) }
        }
        source.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            self.sharedTranscriber?.receive(buffer)
            for lane in self.lanes { lane.realtime?.receive(buffer) }
        }
    }

    /// The chosen apps that are open right now, by name, for the popover.
    var listeningSummary: String? {
        switch audioSource {
        case .systemAudio:
            return nil
        case .microphone:
            return "Listening to your microphone"
        case .apps:
            let open = ListenableApp.running.filter { chosenApps.contains($0.bundleID) }.map(\.name)
            if open.isEmpty { return chosenApps.isEmpty ? "No apps chosen yet" : "None of the chosen apps is open" }
            return "Listening to " + (open.count <= 2 ? open.joined(separator: " and ") : "\(open[0]), \(open[1]) and \(open.count - 2) more")
        }
    }

    // MARK: - Session control

    /// One engine running in a session: where its output goes, and whichever
    /// machinery produces it. Local providers share a transcriber and differ
    /// only in translator; Realtime takes audio directly and has neither.
    private struct Lane {
        let provider: TranslationProvider
        let stream: SubtitleStream
        var translator: TextTranslating?
        var realtime: OpenAIRealtimeService?
        /// What is waiting between recognition and translation, so a label,
        /// a language and the original words stay with the line they came from.
        var pending: [(speaker: Int?, language: String?, original: String?)] = []
    }

    /// Which engines this session will run. One normally; several when
    /// comparison mode is on.
    var activeProviders: [TranslationProvider] {
        guard comparisonMode, comparedProviders.count >= 2 else { return [provider] }
        return TranslationProvider.allCases.filter { comparedProviders.contains($0) }
    }

    func start() {
        let providers = activeProviders
        Log.info(.app, "Start requested — \(providers.map(\.shortLabel).joined(separator: " vs ")), "
            + "\(sourceLanguage.displayName) → \(targetLanguage.displayName)")
        errorDetail = nil

        // Every engine needs its key before anything starts, so a missing one
        // fails immediately rather than half-way through a comparison.
        for candidate in providers where !hosted.isActive && KeychainService.loadAPIKey(for: candidate) == nil {
            hasAPIKey = provider == candidate ? false : hasAPIKey
            status = .missingAPIKey
            errorDetail = providers.count > 1
                ? "\(candidate.credentialName) needs an API key before it can be compared."
                : "Add your API key in Settings to start translating."
            Log.error(.app, "No API key for \(candidate.displayName)")
            return
        }

        // Pick the source first: choosing apps that aren't open is the one
        // mistake worth catching before anything else spins up.
        let source: AudioCapturing
        switch audioSource {
        case .systemAudio:
            systemCapture.scope = .everything
            source = systemCapture
        case .apps:
            let pids = ListenableApp.running.filter { chosenApps.contains($0.bundleID) }.map(\.pid)
            guard !pids.isEmpty else {
                let message = CaptureError.noChosenAppRunning.localizedDescription
                status = .error(message)
                errorDetail = message
                Log.error(.app, message)
                return
            }
            systemCapture.scope = .apps(pids)
            source = systemCapture
        case .microphone:
            source = microphoneCapture
        }

        do {
            try buildLanes(for: providers)
        } catch let error as EngineError {
            status = .error(error.localizedDescription)
            errorDetail = error.localizedDescription
            Log.error(.app, error.localizedDescription)
            teardownLanes()
            return
        } catch {
            fail(with: error.localizedDescription, kind: error)
            return
        }

        SubtitleManager.setComparing(providers.count > 1)
        stats.beginSession()
        transcript.removeAll()
        status = .connecting
        subtitlePanel.show(streams: lanes.map(\.stream), labelled: providers.count > 1)

        capture = source
        Task {
            do {
                try await source.start()
            } catch {
                fail(with: error.localizedDescription, kind: error)
            }
        }
    }

    func stop() {
        Log.info(.app, "Stop requested")
        status = .idle
        audioLevel = 0
        stats.endSession()
        teardownLanes()
        subtitlePanel.hide()
        stopCapture()
    }

    /// Stops whichever source is running. The reference is taken first so a
    /// Start that follows immediately cannot have its own source stopped.
    private func stopCapture() {
        guard let running = capture else { return }
        capture = nil
        Task { await running.stop() }
    }

    func toggle() {
        status.isRunning ? stop() : start()
    }

    // MARK: - Lanes

    private func buildLanes(for providers: [TranslationProvider]) throws {
        teardownLanes()

        let comparing = providers.count > 1
        var built: [Lane] = []

        for (index, candidate) in providers.enumerated() {
            let stream = SubtitleStream(label: candidate.shortLabel, tintIndex: index)

            if candidate == .openaiRealtime {
                let engine = OpenAIRealtimeService(
                    hosted: hosted.isActive ? hosted.token.map { (HostedAccount.realtimeEndpoint, $0) } : nil)
                try engine.start(source: sourceLanguage, target: targetLanguage)
                wire(realtime: engine, to: stream, comparing: comparing)
                built.append(Lane(provider: candidate, stream: stream, realtime: engine))
            } else {
                built.append(Lane(provider: candidate, stream: stream,
                                  translator: try makeTranslator(for: candidate)))
            }
        }

        lanes = built

        // One recogniser feeds every local translator: half the GPU work when
        // comparing two of them, and — more importantly — both then translate
        // exactly the same words, so the comparison is of translators alone.
        if built.contains(where: { $0.translator != nil }) {
            let transcriber = try makeTranscriber()
            transcriber.onFinalText = { [weak self] result in
                MainActor.assumeIsolated { self?.distribute(result) }
            }
            transcriber.onError = { [weak self] (error: Error) in
                MainActor.assumeIsolated {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self?.fail(with: message, kind: error)
                }
            }
            sharedTranscriber = transcriber

            Task {
                do {
                    try await transcriber.start(language: sourceLanguage.language)
                    // Stop may have been pressed while the model loaded; only
                    // the session that is still current gets to say so.
                    guard self.sharedTranscriber === transcriber else { return }
                    self.status = .listening
                } catch {
                    guard self.sharedTranscriber === transcriber else { return }
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.fail(with: message, kind: error)
                }
            }
        }

        for (index, lane) in lanes.enumerated() where lane.translator != nil {
            wire(translator: lane.translator!, laneIndex: index, comparing: comparing)
        }
    }

    /// Hands one recognised utterance to every local translator at once.
    private func distribute(_ result: TranscriptionResult) {
        stats.record(language: result.languageCode)
        let showOriginal = SubtitleStyle.shared.showOriginal
        for index in lanes.indices where lanes[index].translator != nil {
            lanes[index].pending.append((result.speaker, result.languageCode, result.text))
            if showOriginal { lanes[index].stream.manager.setOriginal(result.text) }
            lanes[index].translator?.translate(result.text)
        }
    }

    private func wire(translator: TextTranslating, laneIndex: Int, comparing: Bool) {
        let stream = lanes[laneIndex].stream
        let label = lanes[laneIndex].provider.shortLabel

        translator.onPartial = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, laneIndex < self.lanes.count else { return }
                stream.manager.updatePartial(text, speaker: self.lanes[laneIndex].pending.first?.speaker ?? nil)
            }
        }
        translator.onFinal = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, laneIndex < self.lanes.count else { return }
                let waiting = self.lanes[laneIndex].pending.isEmpty
                    ? (speaker: Int?.none, language: String?.none, original: String?.none)
                    : self.lanes[laneIndex].pending.removeFirst()
                stream.manager.complete(text, speaker: waiting.speaker,
                                        original: SubtitleStyle.shared.showOriginal ? waiting.original : nil)
                // Only the first lane counts, otherwise a comparison would
                // tally the same speech once per engine.
                if laneIndex == 0 {
                    self.stats.record(line: text, language: waiting.language)
                    self.keep(translation: text, original: waiting.original, speaker: waiting.speaker)
                }
                if comparing { Log.content(.compare, "[\(label)] \(text)") }
            }
        }
        translator.onFatalError = { [weak self] message in
            MainActor.assumeIsolated { self?.fail(with: message, kind: nil) }
        }
    }

    private func wire(realtime: OpenAIRealtimeService, to stream: SubtitleStream, comparing: Bool) {
        let label = TranslationProvider.openaiRealtime.shortLabel
        realtime.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                // Only let Realtime drive status when it is the only engine;
                // in a comparison the local pipeline owns it.
                guard let self, self.lanes.count <= 1 else { return }
                self.applyEngineState(state)
            }
        }
        realtime.onPartialTranslation = { text, _ in
            MainActor.assumeIsolated { stream.manager.updatePartial(text) }
        }
        realtime.onSourceTranscript = { text in
            MainActor.assumeIsolated {
                if SubtitleStyle.shared.showOriginal { stream.manager.setOriginal(text) }
            }
        }
        realtime.onFinalTranslation = { [weak self] text, _ in
            MainActor.assumeIsolated {
                stream.manager.complete(text)
                // Realtime only counts when it is the engine, not the rival.
                if let self, self.lanes.first?.realtime != nil {
                    self.stats.record(line: text)
                    // Realtime's source transcript is not aligned to its
                    // translated sentences, so the transcript has no original.
                    self.keep(translation: text, original: nil, speaker: nil)
                }
                if comparing { Log.content(.compare, "[\(label)] \(text)") }
            }
        }
        realtime.onFatalError = { [weak self] message in
            MainActor.assumeIsolated {
                // A failing comparison engine should not end the session.
                guard let self else { return }
                if self.lanes.count > 1 {
                    Log.error(.compare, "\(label) stopped: \(message)")
                } else {
                    self.fail(with: message, kind: nil)
                }
            }
        }
    }

    private func teardownLanes() {
        for lane in lanes {
            lane.translator?.cancel()
            lane.realtime?.stop()
            lane.stream.manager.clear()
        }
        lanes.removeAll()

        if let transcriber = sharedTranscriber {
            sharedTranscriber = nil
            Task { await transcriber.stop() }
        }
    }

    private func makeTranslator(for candidate: TranslationProvider) throws -> TextTranslating {
        // Hosted Local mode: the API owns the prompt and picks the model.
        if hosted.isActive, let token = hosted.token {
            return HostedTranslator(token: token, source: sourceLanguage, target: targetLanguage)
        }
        guard let apiKey = KeychainService.loadAPIKey(for: candidate) else {
            throw EngineError.missingAPIKey(candidate)
        }
        switch candidate {
        case .claude:
            return ClaudeTranslator(apiKey: apiKey, model: claudeModel,
                                    source: sourceLanguage, target: targetLanguage)
        case .openai:
            return OpenAITextTranslator(apiKey: apiKey, model: openAIModel,
                                        source: sourceLanguage, target: targetLanguage)
        case .openaiRealtime:
            throw EngineError.setupFailed("Realtime takes audio directly and has no translator.")
        }
    }

    private func makeTranscriber() throws -> SpeechTranscribing {
        switch speechEngine {
        case .whisper:
            let store = ModelStore.whisper
            guard store.isInstalled(whisperModel) else {
                throw EngineError.setupFailed(
                    "The \(whisperModel.displayName) speech model isn't downloaded yet. "
                    + "Open Settings to download it."
                )
            }
            let vad = ModelStore.voiceActivity
            if useVoiceFilter, !vad.isInstalled(.silero) {
                Log.error(.whisper, "Voice filter is on but its model isn't downloaded; running without it")
            }
            return WhisperTranscriptionService(
                model: whisperModel,
                modelURL: store.url(for: whisperModel),
                speakers: makeSpeakerService(),
                expectedSpeakers: expectedSpeakers > 0 ? expectedSpeakers : nil,
                vadModelURL: useVoiceFilter && vad.isInstalled(.silero) ? vad.url(for: .silero) : nil)
        case .apple:
            guard #available(macOS 26.0, *) else {
                throw EngineError.setupFailed(
                    "Apple's recogniser needs macOS 26. Switch the speech engine to Whisper."
                )
            }
            return SpeechTranscriptionService()
        }
    }

    /// Nil unless labelling is on and the model is present — the transcriber
    /// simply skips labelling rather than failing the whole session.
    private func makeSpeakerService() -> SpeakerEmbeddingService? {
        guard labelSpeakers else { return nil }
        let store = ModelStore.speaker
        guard store.isInstalled(.campPlus) else {
            Log.error(.speakers, "Speaker labelling is on but the model isn't downloaded")
            return nil
        }
        do {
            return try SpeakerEmbeddingService(modelURL: store.url(for: .campPlus))
        } catch {
            Log.error(.speakers, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Transcript

    private func keep(translation: String, original: String?, speaker: Int?) {
        guard keepTranscript else { return }
        transcript.append(TranscriptEntry(time: Date(), speaker: speaker, original: original, translation: translation))
    }

    /// Writes the in-memory transcript to a place the user chooses. This is
    /// the only path by which anything said ever reaches disk.
    func saveTranscript() {
        guard !transcript.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = Transcript.suggestedFileName(for: transcript)
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Transcript.text(for: transcript).write(to: url, atomically: true, encoding: .utf8)
            Log.info(.app, "Transcript saved (\(transcript.count) lines)")
        } catch {
            Log.error(.app, "Could not save the transcript: \(error.localizedDescription)")
        }
    }

    func discardTranscript() {
        transcript.removeAll()
    }

    // MARK: - Shortcut

    private func applyShortcut() {
        hotKey = shortcutEnabled ? GlobalHotKey { [weak self] in self?.toggle() } : nil
    }

    // MARK: - Settings plumbing

    /// Whether the selected recogniser has what it needs on disk. Only Whisper
    /// has a model to download; Apple's arrives on its own at first start.
    var hasSpeechModel: Bool {
        !provider.usesLocalSpeech || speechEngine != .whisper || ModelStore.whisper.isInstalled(whisperModel)
    }

    /// Says up front what Start would otherwise only complain about: a missing
    /// key, or a speech model nobody has downloaded yet. Only the resting
    /// states are rewritten; a running session keeps its own status.
    func refreshReadiness() {
        hasAPIKey = hosted.isActive || KeychainService.hasAPIKey(for: provider)

        switch status {
        case .idle, .missingAPIKey, .missingSpeechModel:
            if !hasAPIKey {
                status = .missingAPIKey
                errorDetail = "Add your API key in Settings to start translating."
            } else if !hasSpeechModel {
                status = .missingSpeechModel
                errorDetail = "Download the \(whisperModel.displayName) speech model in Settings, then press start."
            } else {
                status = .idle
                errorDetail = nil
            }
        default:
            break
        }
    }

    /// The pane that matches the permission the current source needs.
    func openAudioSettings() {
        if audioSource == .microphone {
            SystemAudioCaptureService.openMicrophoneSettings()
        } else {
            SystemAudioCaptureService.openAudioSettings()
        }
    }

    // MARK: - Translation output

    func resetSubtitlePosition() {
        subtitlePanel.resetPosition()
    }

    // MARK: - State plumbing

    private func applyEngineState(_ state: EngineState) {
        // The engine only drives status while a session is running; a
        // deliberate stop has already moved us to .idle.
        guard status.isRunning else { return }
        switch state {
        case .connecting: status = .connecting
        case .ready: status = .listening
        case .reconnecting: status = .reconnecting
        case .idle: break
        }
    }

    private func fail(with message: String, kind: Error?) {
        // Somebody pressed stop — in our UI or macOS's. End the session the
        // same way Stop Translation would, with no error banner.
        if let kind, case CaptureError.stoppedExternally = kind {
            Log.info(.app, "Capture ended externally — stopping cleanly")
            stop()
            return
        }

        Log.error(.app, message)
        audioLevel = 0
        stats.endSession()
        teardownLanes()
        subtitlePanel.hide()
        stopCapture()

        if let kind, case CaptureError.permissionDenied = kind {
            status = .permissionRequired
            errorDetail = "Relay needs permission to hear your Mac's audio. "
                + "Allow it in System Settings, then press start again."
        } else if let kind, case CaptureError.microphoneDenied = kind {
            status = .permissionRequired
            errorDetail = "Relay needs permission to use your microphone. "
                + "Allow it in System Settings, then press start again."
        } else {
            status = .error(message)
            errorDetail = message
        }
    }
}
