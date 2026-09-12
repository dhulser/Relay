import Foundation
import AVFoundation

/// On-device speech recognition with whisper.cpp, including per-utterance
/// language identification.
///
/// Whisper is not a streaming recogniser — it transcribes a complete chunk of
/// audio. So this class does the segmenting: it watches the incoming level,
/// accumulates a phrase, and runs inference once the speaker pauses. At roughly
/// 20–50× realtime on Metal, a 5-second phrase transcribes in well under a
/// second, so the perceived delay is the pause itself rather than the model.
final class WhisperTranscriptionService: SpeechTranscribing {

    var onFinalText: ((TranscriptionResult) -> Void)?
    var onError: ((Error) -> Void)?

    private let model: WhisperModel
    private let modelURL: URL

    private var context: OpaquePointer?
    private let converter = AudioConverter(target: WhisperTranscriptionService.whisperFormat)
    private let inference = DispatchQueue(label: "co.kevel.LiveTranslator.whisper", qos: .userInitiated)

    /// Whisper is trained on 16 kHz mono float audio and accepts nothing else.
    static let whisperFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else {
            fatalError("Could not build the 16 kHz mono Float32 format")
        }
        return format
    }()

    // MARK: - Segmentation tuning

    private static let sampleRate = 16_000
    /// RMS below this counts as silence. System audio is digital and clean, so
    /// this can sit low without picking up noise.
    private static let silenceThreshold: Float = 0.006
    /// How much quiet ends a phrase. Too short chops mid-sentence; too long
    /// adds latency to every subtitle.
    private static let endOfPhraseSilence = Int(Double(sampleRate) * 0.65)
    /// Ignore blips so a keyboard click doesn't become an utterance.
    private static let minimumPhrase = Int(Double(sampleRate) * 0.35)
    /// Someone talking without pause still needs subtitles eventually.
    private static let maximumPhrase = Int(Double(sampleRate) * 18.0)
    /// Whisper invents text on silence; this filters those segments out.
    private static let noSpeechCeiling: Float = 0.6

    private var phrase: [Float] = []
    private var silenceRun = 0
    private var speaking = false
    private var language: Language?
    private var busy = false
    private var loggedFirstAudio = false

    init(model: WhisperModel, modelURL: URL) {
        self.model = model
        self.modelURL = modelURL
    }

    deinit {
        if let context { whisper_free(context) }
    }

    // MARK: - Lifecycle

    func start(language: Language?) async throws {
        self.language = language

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EngineError.setupFailed(
                "The \(model.displayName) speech model isn't downloaded yet. Open Settings to get it."
            )
        }

        var params = whisper_context_default_params()
        params.use_gpu = true

        let loaded: OpaquePointer? = modelURL.path.withCString { path in
            whisper_init_from_file_with_params(path, params)
        }
        guard let loaded else {
            throw EngineError.setupFailed("Could not load the \(model.displayName) speech model.")
        }
        context = loaded

        phrase.removeAll(keepingCapacity: true)
        silenceRun = 0
        speaking = false
        loggedFirstAudio = false

        let mode = language.map { "fixed to \($0.displayName)" } ?? "auto-detecting"
        Log.info(.whisper, "Loaded \(model.displayName) model, \(mode)")
    }

    func stop() async {
        // Flush whatever is mid-phrase so the last line isn't lost.
        if phrase.count >= Self.minimumPhrase {
            transcribe(Array(phrase))
        }
        phrase.removeAll(keepingCapacity: true)
        speaking = false

        inference.sync {}   // let any in-flight inference finish before freeing
        if let context {
            whisper_free(context)
            self.context = nil
        }
        Log.info(.whisper, "Stopped")
    }

    // MARK: - Audio in (capture queue)

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard context != nil,
              let converted = converter.convert(buffer),
              let samples = converted.floatChannelData
        else { return }

        if !loggedFirstAudio {
            loggedFirstAudio = true
            Log.info(.whisper, "Receiving audio")
        }

        let frames = Int(converted.frameLength)
        let incoming = UnsafeBufferPointer(start: samples[0], count: frames)
        segment(Array(incoming))
    }

    /// Level-based phrase detection. Whisper has its own VAD model, but that's
    /// a second download for something a few lines of RMS can do on audio this
    /// clean.
    private func segment(_ samples: [Float]) {
        let energy = Self.rms(samples)

        if energy >= Self.silenceThreshold {
            speaking = true
            silenceRun = 0
            phrase.append(contentsOf: samples)
        } else if speaking {
            // Keep trailing silence: Whisper transcribes better with a little
            // padding after the words than with an abrupt cut.
            phrase.append(contentsOf: samples)
            silenceRun += samples.count
        }

        let phraseEnded = speaking && silenceRun >= Self.endOfPhraseSilence
        let phraseTooLong = phrase.count >= Self.maximumPhrase
        guard phraseEnded || phraseTooLong else { return }

        let captured = phrase
        phrase.removeAll(keepingCapacity: true)
        silenceRun = 0
        speaking = false

        guard captured.count >= Self.minimumPhrase else { return }
        transcribe(captured)
    }

    // MARK: - Inference

    private func transcribe(_ samples: [Float]) {
        // Drop a phrase rather than queue it if inference is still busy —
        // backed-up subtitles are worse than a missing one.
        guard !busy else {
            Log.info(.whisper, "Skipped a phrase (still transcribing the previous one)")
            return
        }
        busy = true

        inference.async { [weak self] in
            guard let self, let context = self.context else { return }
            defer { self.busy = false }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false          // Claude/OpenAI does the translating
            params.no_timestamps = true
            params.no_context = true          // each phrase stands alone
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

            let started = Date()
            // "auto" makes whisper identify the language itself; a fixed code
            // is more accurate when the user already knows it.
            let requested = self.language?.isoCode ?? "auto"
            let status: Int32 = requested.withCString { languagePointer in
                params.language = languagePointer
                return samples.withUnsafeBufferPointer { audio in
                    whisper_full(context, params, audio.baseAddress, Int32(audio.count))
                }
            }

            guard status == 0 else {
                Log.error(.whisper, "Inference failed (\(status))")
                return
            }

            var text = ""
            for index in 0..<whisper_full_n_segments(context) {
                // Whisper hallucinates confident-looking text on near-silence.
                guard whisper_full_get_segment_no_speech_prob(context, index) < Self.noSpeechCeiling,
                      let segment = whisper_full_get_segment_text(context, index)
                else { continue }
                text += String(cString: segment)
            }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }

            let detected = WhisperRuntime.languageCode(for: whisper_full_lang_id(context))
            let seconds = Double(samples.count) / Double(Self.sampleRate)
            let elapsed = Date().timeIntervalSince(started)
            Log.info(.whisper, "[\(detected ?? "??")] \(String(format: "%.1f", seconds))s audio in "
                + "\(String(format: "%.2f", elapsed))s — \(cleaned)")

            let result = TranscriptionResult(text: cleaned, languageCode: detected)
            DispatchQueue.main.async { self.onFinalText?(result) }
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
