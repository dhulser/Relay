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

    var displayText: String {
        switch self {
        case .idle: return "● Ready"
        case .requestingPermission: return "● Requesting permission…"
        case .connecting: return "● Starting…"
        case .listening: return "● Listening"
        case .reconnecting: return "● Reconnecting…"
        case .permissionRequired: return "⚠ Permission Required"
        case .missingAPIKey: return "⚠ API Key Needed"
        case .error: return "⚠ Error"
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
    private static let sourceKey = "sourceLanguage"
    private static let lastExplicitSourceKey = "lastExplicitSourceLanguage"
    private static let targetKey = "targetLanguage"

    private let capture = SystemAudioCaptureService()
    private var engine: TranslationEngine?

    let subtitles = SubtitleManager()
    private lazy var subtitlePanel = SubtitlePanelController(manager: subtitles)

    init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: Self.providerKey).flatMap(TranslationProvider.init) ?? .claude
        claudeModel = defaults.string(forKey: Self.modelKey).flatMap(ClaudeModel.init) ?? .haiku45
        openAIModel = defaults.string(forKey: Self.openAIModelKey).flatMap(OpenAITextModel.init) ?? .luna
        speechEngine = defaults.string(forKey: Self.speechEngineKey).flatMap(SpeechEngine.init) ?? .whisper
        whisperModel = defaults.string(forKey: Self.whisperModelKey).flatMap(WhisperModel.init) ?? .small
        labelSpeakers = defaults.bool(forKey: Self.labelSpeakersKey)
        expectedSpeakers = defaults.integer(forKey: Self.expectedSpeakersKey)
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
            self?.engine?.receive(buffer)
        }

        reconcileSourceLanguage()
        refreshAPIKeyState()
        Log.info(.app, "whisper.cpp \(WhisperRuntime.version), "
            + "\(WhisperRuntime.languageCount) languages; "
            + "sherpa-onnx \(SpeakerRuntime.version)")
    }

    // MARK: - Session control

    func start() {
        Log.info(.app, "Start requested — \(provider.displayName), \(sourceLanguage.displayName) → \(targetLanguage.displayName)")
        errorDetail = nil
        needsRelaunch = false

        guard SystemAudioCaptureService.hasPermission else {
            status = .requestingPermission
            SystemAudioCaptureService.requestPermission()
            status = .permissionRequired
            errorDetail = "Live Translator needs Screen Recording permission to capture system audio. "
                + "Grant it in System Settings, then quit and reopen Live Translator."
            needsRelaunch = true
            Log.error(.app, "Screen Recording permission not granted")
            return
        }

        let engine: TranslationEngine
        do {
            engine = try makeEngine()
            try engine.start(source: sourceLanguage, target: targetLanguage)
        } catch let error as EngineError {
            if case .missingAPIKey = error {
                hasAPIKey = false
                status = .missingAPIKey
            } else {
                status = .error(error.localizedDescription)
            }
            errorDetail = error.localizedDescription
            Log.error(.app, error.localizedDescription)
            return
        } catch {
            fail(with: error.localizedDescription, kind: error)
            return
        }

        engine.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.applyEngineState(state) }
        }
        engine.onPartialTranslation = { [weak self] text, speaker in
            MainActor.assumeIsolated { self?.subtitles.updatePartial(text, speaker: speaker) }
        }
        engine.onFinalTranslation = { [weak self] text, speaker in
            MainActor.assumeIsolated { self?.subtitles.complete(text, speaker: speaker) }
        }
        engine.onFatalError = { [weak self] message in
            MainActor.assumeIsolated { self?.fail(with: message, kind: nil) }
        }
        self.engine = engine
        status = .connecting
        subtitles.clear()
        subtitlePanel.show()

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
        engine?.stop()
        engine = nil
        subtitlePanel.hide()
        subtitles.clear()
        Task { await capture.stop() }
    }

    func toggle() {
        status.isRunning ? stop() : start()
    }

    private func makeEngine() throws -> TranslationEngine {
        guard let apiKey = KeychainService.loadAPIKey(for: provider) else {
            throw EngineError.missingAPIKey(provider)
        }

        if provider == .openaiRealtime {
            return OpenAIRealtimeService()
        }

        let translator: TextTranslating = provider == .claude
            ? ClaudeTranslator(apiKey: apiKey, model: claudeModel,
                               source: sourceLanguage, target: targetLanguage)
            : OpenAITextTranslator(apiKey: apiKey, model: openAIModel,
                                   source: sourceLanguage, target: targetLanguage)

        let transcriber = try makeTranscriber()
        Log.info(.app, "Pipeline: \(speechEngine.displayName) → "
            + "\(provider == .claude ? claudeModel.rawValue : openAIModel.rawValue)")
        return LocalPipelineEngine(transcriber: transcriber, translator: translator)
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
            return WhisperTranscriptionService(model: whisperModel,
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
            errorDetail = "Add your \(provider.credentialName) API key in Settings to start translating."
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
        engine?.stop()
        engine = nil
        subtitlePanel.hide()
        subtitles.clear()
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
