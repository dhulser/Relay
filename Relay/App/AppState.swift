import Foundation
import Combine

/// Languages offered in the source/target pickers.
enum Language: String, CaseIterable, Identifiable, Codable {
    case spanish, english, french, german, italian, portuguese, japanese, korean, chinese

    var id: String { rawValue }

    /// ISO-639-1, used for the OpenAI language fields and to build the `Locale`
    /// for on-device speech recognition.
    var isoCode: String {
        switch self {
        case .spanish: return "es"
        case .english: return "en"
        case .french: return "fr"
        case .german: return "de"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .chinese: return "zh"
        }
    }

    var displayName: String {
        switch self {
        case .spanish: return "Spanish"
        case .english: return "English"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        }
    }
}

enum SessionStatus: Equatable {
    case idle
    case requestingPermission
    case connecting
    case listening
    case reconnecting
    case permissionRequired
    case missingAPIKey
    case error(String)

    /// Plain language, lower case, no warning glyphs — the status dot already
    /// carries the severity, so the words can just say what is happening.
    var friendlyText: String {
        switch self {
        case .idle: return "Ready when you are"
        case .requestingPermission: return "Asking for permission…"
        case .connecting: return "Warming up…"
        case .listening: return "Listening"
        case .reconnecting: return "Reconnecting…"
        case .permissionRequired: return "Needs permission to hear your Mac"
        case .missingAPIKey: return "Needs an API key"
        case .error: return "Something went wrong"
        }
    }

    var isRunning: Bool {
        switch self {
        case .idle, .permissionRequired, .missingAPIKey, .error: return false
        case .requestingPermission, .connecting, .listening, .reconnecting: return true
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: SessionStatus = .idle
    @Published var errorDetail: String?

    /// 0…1 peak level of the captured system audio, for the popover meter.
    @Published var audioLevel: Float = 0

    /// Set when Screen Recording was just granted and macOS needs a relaunch.
    @Published var needsRelaunch = false

    /// Whether the *selected* provider has a key stored.
    @Published var hasAPIKey = false

    @Published var provider: TranslationProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: Self.providerKey)
            reconcileSourceLanguage()
            refreshAPIKeyState()
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
        }
    }
    @Published var whisperModel: WhisperModel {
        didSet { defaults.set(whisperModel.rawValue, forKey: Self.whisperModelKey) }
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

    private let defaults = UserDefaults.standard
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

    private let capture = SystemAudioCaptureService()
    private var lanes: [Lane] = []

    /// One recogniser shared by every local translator in the session.
    private var sharedTranscriber: SpeechTranscribing?

    private lazy var subtitlePanel = SubtitlePanelController()

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

        capture.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.audioLevel = level }
        }
        capture.onError = { [weak self] error in
            MainActor.assumeIsolated { self?.fail(with: error.localizedDescription, kind: error) }
        }
        capture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            self.sharedTranscriber?.receive(buffer)
            for lane in self.lanes { lane.realtime?.receive(buffer) }
        }

        reconcileSourceLanguage()
        refreshAPIKeyState()
        Log.info(.app, "whisper.cpp \(WhisperRuntime.version), "
            + "\(WhisperRuntime.languageCount) languages; "
            + "sherpa-onnx \(SpeakerRuntime.version)")
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
        /// Speakers waiting between recognition and translation, so a label
        /// stays with the line it came from.
        var pendingSpeakers: [Int?] = []
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
        needsRelaunch = false

        guard SystemAudioCaptureService.hasPermission else {
            status = .requestingPermission
            SystemAudioCaptureService.requestPermission()
            status = .permissionRequired
            errorDetail = "Relay needs Screen Recording permission to hear your Mac. "
                + "Grant it in System Settings, then quit and reopen Relay."
            needsRelaunch = true
            Log.error(.app, "Screen Recording permission not granted")
            return
        }

        // Every engine needs its key before anything starts, so a missing one
        // fails immediately rather than half-way through a comparison.
        for candidate in providers where KeychainService.loadAPIKey(for: candidate) == nil {
            hasAPIKey = provider == candidate ? false : hasAPIKey
            status = .missingAPIKey
            errorDetail = providers.count > 1
                ? "\(candidate.credentialName) needs an API key before it can be compared."
                : "Add your API key in Settings to start translating."
            Log.error(.app, "No API key for \(candidate.displayName)")
            return
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
        status = .connecting
        subtitlePanel.show(streams: lanes.map(\.stream), labelled: providers.count > 1)

        Task {
            do {
                try await capture.start()
            } catch {
                fail(with: error.localizedDescription, kind: error)
            }
        }
    }

    func stop() {
        Log.info(.app, "Stop requested")
        status = .idle
        audioLevel = 0
        teardownLanes()
        subtitlePanel.hide()
        Task { await capture.stop() }
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
                let engine = OpenAIRealtimeService()
                try engine.start(source: sourceLanguage, target: targetLanguage)
                var lane = Lane(provider: candidate, stream: stream, realtime: engine)
                wire(realtime: engine, to: stream, comparing: comparing)
                built.append(lane)
                lane.pendingSpeakers = []
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
                    self.status = .listening
                } catch {
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
        for index in lanes.indices where lanes[index].translator != nil {
            lanes[index].pendingSpeakers.append(result.speaker)
            lanes[index].translator?.translate(result.text)
        }
    }

    private func wire(translator: TextTranslating, laneIndex: Int, comparing: Bool) {
        let stream = lanes[laneIndex].stream
        let label = lanes[laneIndex].provider.shortLabel

        translator.onPartial = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, laneIndex < self.lanes.count else { return }
                stream.manager.updatePartial(text, speaker: self.lanes[laneIndex].pendingSpeakers.first ?? nil)
            }
        }
        translator.onFinal = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, laneIndex < self.lanes.count else { return }
                let speaker = self.lanes[laneIndex].pendingSpeakers.isEmpty
                    ? nil : self.lanes[laneIndex].pendingSpeakers.removeFirst()
                stream.manager.complete(text, speaker: speaker)
                if comparing { Log.info(.compare, "[\(label)] \(text)") }
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
        realtime.onFinalTranslation = { text, _ in
            MainActor.assumeIsolated {
                stream.manager.complete(text)
                if comparing { Log.info(.compare, "[\(label)] \(text)") }
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
            return WhisperTranscriptionService(
                model: whisperModel,
                modelURL: store.url(for: whisperModel),
                speakers: makeSpeakerService(),
                expectedSpeakers: expectedSpeakers > 0 ? expectedSpeakers : nil)
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

    // MARK: - Settings plumbing

    func refreshAPIKeyState() {
        hasAPIKey = KeychainService.hasAPIKey(for: provider)

        // Surface a missing key immediately rather than showing "Ready" and
        // only admitting otherwise once Start is pressed.
        if hasAPIKey, status == .missingAPIKey {
            status = .idle
            errorDetail = nil
        } else if !hasAPIKey, status == .idle {
            status = .missingAPIKey
            errorDetail = "Add your API key in Settings to start translating."
        }
    }

    func openScreenRecordingSettings() {
        SystemAudioCaptureService.openScreenRecordingSettings()
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
        teardownLanes()
        subtitlePanel.hide()
        Task { await capture.stop() }

        if let kind, case CaptureError.permissionDenied = kind {
            status = .permissionRequired
            needsRelaunch = true
        } else {
            status = .error(message)
        }
        errorDetail = message
    }
}
