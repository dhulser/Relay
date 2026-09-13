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
///
/// Threads: `receive` runs on the capture queue, inference on its own serial
/// queue, and `start`/`stop` on whoever owns the session. Everything they share
/// — the phrase being built, the backlog, the busy flag, the model context — is
/// guarded by one lock, and the context is only ever freed on the inference
/// queue, after every queued phrase has run.
final class WhisperTranscriptionService: SpeechTranscribing {

    var onFinalText: ((TranscriptionResult) -> Void)?
    var onError: ((Error) -> Void)?

    private let model: WhisperModel
    private let modelURL: URL
    /// Silero VAD weights, when the user turned the voice filter on and the
    /// model is downloaded. Whisper then drops music and noise from each
    /// phrase before transcribing it.
    private let vadModelURL: URL?

    /// Optional voiceprint labelling. Nil when the user hasn't enabled it or
    /// the model isn't downloaded. Touched only on the inference queue.
    private let speakers: SpeakerEmbeddingService?
    private let clusterer = SpeakerClusterer()

    private let converter = AudioConverter(target: WhisperTranscriptionService.whisperFormat)
    private let inference = DispatchQueue(label: "co.kevel.Relay.whisper", qos: .userInitiated)
    private let lock = NSLock()

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
    /// this can sit low without picking up noise. A noisier source raises the
    /// effective threshold through `noiseFloor`.
    private static let silenceThreshold: Float = 0.006
    /// Silence is judged at this multiple of the tracked noise floor, or the
    /// fixed threshold, whichever is higher.
    private static let floorMultiple: Float = 3
    /// How fast the floor is allowed to creep back up, per 20 ms buffer, so a
    /// room that gets louder is followed within ten seconds or so.
    private static let floorRise: Float = 1.003
    /// How much quiet ends a phrase. Whisper is not a streaming model — it
    /// transcribes a finished chunk — so this pause *is* the latency floor for
    /// the local pipeline. Shorter feels live but fragments sentences; this is
    /// the first dial to turn if captions start breaking mid-thought.
    private static let endOfPhraseSilence = Int(Double(sampleRate) * 0.32)
    /// Ignore blips so a keyboard click doesn't become an utterance.
    private static let minimumPhrase = Int(Double(sampleRate) * 0.35)
    /// Someone talking without pause still needs subtitles eventually. Kept
    /// short so an uninterrupted monologue still produces lines steadily
    /// rather than one wall of text when they finally breathe.
    private static let maximumPhrase = Int(Double(sampleRate) * 7.0)

    /// Encoder context, in frames — roughly 50 per second of audio. The model
    /// defaults to 1500 (30s) and pays for all of it regardless of how short
    /// the phrase is; 512 covers ~10s, comfortably above `maximumPhrase`, and
    /// measured 48% faster on identical output.
    private static let encoderContext: Int32 = 512
    /// Whisper invents text on silence; this filters those segments out.
    private static let noSpeechCeiling: Float = 0.6

    /// Minimum speech before a clip may introduce a *new* speaker. Measured:
    /// the same voice scores 0.81 against itself at 1.5s but only 0.58 at 0.4s,
    /// so a short clip that matches nobody is usually just short. Shorter clips
    /// are still matched against speakers already known.
    private static let minimumSpeakerAudio = 1.2

    /// Phrases waiting on inference. Transcription runs ~9x faster than
    /// realtime, so a short backlog drains quickly and dropping outright — as
    /// this used to — simply lost captions the user was owed.
    private static let maximumQueued = 2

    // Guarded by `lock`.
    private var context: OpaquePointer?
    private var phrase: [Float] = []
    private var silenceRun = 0
    private var speaking = false
    private var queued: [[Float]] = []
    private var busy = false
    /// Quietest recent level. Digital silence takes it to zero, where the
    /// fixed threshold applies exactly as before; a microphone in a room, or
    /// a video with a soundtrack, lifts it so gaps between phrases still show.
    private var noiseFloor: Float = 1

    private var language: Language?
    private var loggedFirstAudio = false

    init(model: WhisperModel, modelURL: URL, speakers: SpeakerEmbeddingService? = nil,
         expectedSpeakers: Int? = nil, vadModelURL: URL? = nil) {
        self.model = model
        self.modelURL = modelURL
        self.speakers = speakers
        self.vadModelURL = vadModelURL
        if let expectedSpeakers { clusterer.setMaximum(expectedSpeakers) }
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

        lock.withLock {
            context = loaded
            phrase.removeAll(keepingCapacity: true)
            queued.removeAll()
            silenceRun = 0
            speaking = false
            busy = false
            noiseFloor = 1
        }
        loggedFirstAudio = false
        clusterer.reset()

        let mode = language.map { "fixed to \($0.displayName)" } ?? "auto-detecting"
        let filter = vadModelURL == nil ? "" : ", voice filter on"
        Log.info(.whisper, "Loaded \(model.displayName) model, \(mode)\(filter)")
    }

    func stop() async {
        // Flush whatever is mid-phrase so the last line isn't lost.
        let remainder: [Float] = lock.withLock {
            defer {
                phrase.removeAll(keepingCapacity: true)
                silenceRun = 0
                speaking = false
            }
            return phrase.count >= Self.minimumPhrase ? phrase : []
        }
        if !remainder.isEmpty { transcribe(remainder) }

        // The drain loop runs every queued phrase on this queue before this
        // block is reached, so nothing is mid-inference when the model goes.
        inference.sync {
            lock.withLock {
                if let context { whisper_free(context) }
                context = nil
            }
        }
        Log.info(.whisper, "Stopped")
    }

    // MARK: - Audio in (capture queue)

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ context != nil }),
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

        let captured: [Float]? = lock.withLock {
            noiseFloor = min(noiseFloor * Self.floorRise + 0.00001, energy)
            let threshold = max(Self.silenceThreshold, noiseFloor * Self.floorMultiple)

            if energy >= threshold {
                speaking = true
                silenceRun = 0
                phrase.append(contentsOf: samples)
            } else if speaking {
                // Keep trailing silence: Whisper transcribes better with a
                // little padding after the words than with an abrupt cut.
                phrase.append(contentsOf: samples)
                silenceRun += samples.count
            }

            let phraseEnded = speaking && silenceRun >= Self.endOfPhraseSilence
            let phraseTooLong = phrase.count >= Self.maximumPhrase
            guard phraseEnded || phraseTooLong else { return nil }

            defer {
                phrase.removeAll(keepingCapacity: true)
                silenceRun = 0
                speaking = false
            }
            return phrase.count >= Self.minimumPhrase ? phrase : nil
        }

        if let captured { transcribe(captured) }
    }

    // MARK: - Inference

    /// Queues a phrase and starts the drain loop if it isn't already running.
    /// Only when the backlog would grow unbounded — which means inference is
    /// losing to realtime — is the oldest phrase discarded, since stale
    /// subtitles help nobody.
    private func transcribe(_ samples: [Float]) {
        let shouldStart: Bool = lock.withLock {
            queued.append(samples)
            if queued.count > Self.maximumQueued {
                queued.removeFirst()
                Log.info(.whisper, "Dropped the oldest queued phrase — inference is behind")
            }
            if busy { return false }
            busy = true
            return true
        }
        guard shouldStart else { return }

        inference.async { [weak self] in
            guard let self else { return }
            while true {
                let next: [Float]? = self.lock.withLock {
                    if self.queued.isEmpty {
                        self.busy = false
                        return nil
                    }
                    return self.queued.removeFirst()
                }
                guard let next else { return }
                self.run(next)
            }
        }
    }

    /// One whisper_full call. Inference queue only.
    private func run(_ samples: [Float]) {
        // Read under the lock, but hold the pointer for the call: the only
        // place it is freed is this same queue, after this returns.
        guard let context = lock.withLock({ self.context }) else { return }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false          // Claude/OpenAI does the translating
        params.no_timestamps = true
        params.no_context = true          // each phrase stands alone
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.audio_ctx = Self.encoderContext

        let started = Date()
        // "auto" makes whisper identify the language itself; a fixed code
        // is more accurate when the user already knows it.
        let requested = self.language?.isoCode ?? "auto"
        let vadPath = vadModelURL?.path ?? ""
        let status: Int32 = requested.withCString { languagePointer in
            vadPath.withCString { vadPointer in
                params.language = languagePointer
                if !vadPath.isEmpty {
                    params.vad = true
                    params.vad_model_path = vadPointer
                }
                return samples.withUnsafeBufferPointer { audio in
                    whisper_full(context, params, audio.baseAddress, Int32(audio.count))
                }
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

        // The voiceprint is computed from exactly the audio that produced
        // this line, so the label can never drift out of sync with it.
        var speaker: Int?
        if let speakers {
            let duration = Double(samples.count) / Double(Self.sampleRate)
            if let embedding = speakers.embed(samples) {
                // Short clips still get matched — that part is reliable.
                // They just may not introduce someone new.
                speaker = clusterer.assign(
                    embedding,
                    canCreateSpeaker: duration >= Self.minimumSpeakerAudio
                )
            } else {
                speaker = clusterer.inheritLastSpeaker()
            }
        }

        let seconds = Double(samples.count) / Double(Self.sampleRate)
        let elapsed = Date().timeIntervalSince(started)
        let who = speaker.map { "S\($0) " } ?? ""
        Log.info(.whisper, "\(who)[\(detected ?? "??")] \(String(format: "%.1f", seconds))s audio in "
            + "\(String(format: "%.2f", elapsed))s")
        Log.content(.whisper, cleaned)

        let result = TranscriptionResult(text: cleaned, languageCode: detected, speaker: speaker)
        DispatchQueue.main.async { self.onFinalText?(result) }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
