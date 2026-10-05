import Foundation
import AVFoundation
import Combine

/// Push to talk, the other way round: hold, say something in your language,
/// release, and the other person hears it in theirs.
///
/// Hold → microphone buffers go to a Whisper instance that knows your
/// language → release flushes the phrase → the existing translators, with the
/// direction reversed and a spoken-output prompt → a voice → the output.
/// Everything is queued in order, so two quick sentences come out as two
/// sentences. Pressing the key while it is speaking cuts the speech off.
@MainActor
final class SpokenReplyController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        /// Recognising or translating; from the outside the same wait.
        case working
        case speaking
    }

    /// What the controller needs from the app to run one session.
    struct Setup {
        /// The language you speak: the subtitles' target.
        let myLanguage: Language
        /// Theirs, worked out at the moment it is needed so auto-detect can
        /// use the most recent incoming line. Nil when nothing is known yet.
        let theirLanguage: () -> Language?
        let transcriber: WhisperTranscriptionService
        let makeTranslator: (_ from: Language, _ to: Language) throws -> TextTranslating
        let synthesizer: SpeechSynthesizing
        /// Used for a sentence when `synthesizer` fails, so the far side is
        /// never left in silence.
        let fallback: SpeechSynthesizing?
        /// Whether to open the microphone here. False when the session is
        /// already listening to it and routes buffers in.
        let ownMicrophone: Bool
        /// The subtitle stream the You line goes to.
        let stream: SubtitleStream
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var running = false
    /// True once the recogniser and the output are up and a hold will be
    /// heard. Loading the speech model takes a few seconds the first time.
    @Published private(set) var ready = false

    /// Something you said and what was spoken for it, for the transcript and
    /// the tally.
    var onLine: ((_ said: String, _ translation: String, _ language: Language) -> Void)?
    /// A problem worth a line under the status. Nil clears it.
    var onWarning: ((String?) -> Void)?

    /// Read on the audio thread.
    let gate = Gate()

    private var setup: Setup?
    private var microphone: MicrophoneCaptureService?
    private let output = VoiceOutputService()
    private var translators: [Language: TextTranslating] = [:]
    /// What was said, waiting for its translation, with the language it is
    /// being translated into.
    private var pending: [(said: String, language: Language)] = []
    private var speechQueue: [(text: String, language: Language)] = []
    private var speechTask: Task<Void, Never>?
    private var holdStarted: Date?
    private var holdCeiling: Timer?
    private var catchTimer: Timer?
    private var noticeTimer: Timer?

    /// Nobody can usefully hold for longer; a lost key-up would otherwise
    /// record for ever.
    static let maximumHold: TimeInterval = 60

    // MARK: - Lifecycle

    func start(_ setup: Setup) async throws {
        guard !running else { return }
        self.setup = setup
        running = true

        try output.start()

        setup.transcriber.onFinalText = { [weak self] result in
            MainActor.assumeIsolated { self?.heard(result.text) }
        }
        setup.transcriber.onError = { [weak self] error in
            MainActor.assumeIsolated {
                self?.onWarning?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        try await setup.transcriber.start(language: setup.myLanguage)
        guard running else { return }
        gate.setTranscriber(setup.transcriber)
        ready = true

        if setup.ownMicrophone {
            let microphone = MicrophoneCaptureService()
            microphone.onAudioBuffer = { [weak self] buffer in self?.receive(buffer) }
            microphone.onError = { [weak self] error in
                MainActor.assumeIsolated { self?.onWarning?(error.localizedDescription) }
            }
            try await microphone.start()
            self.microphone = microphone
        }
        Log.info(.speak, "Speak ready: \(setup.myLanguage.displayName) → \(setup.theirLanguage()?.displayName ?? "their language, once heard"), voice \(setup.synthesizer.name)")
    }

    func stop() {
        guard running else { return }
        running = false
        ready = false
        gate.setTranscriber(nil)
        if gate.isHolding { gate.setHolding(false) }
        holdCeiling?.invalidate(); holdCeiling = nil
        catchTimer?.invalidate(); catchTimer = nil
        noticeTimer?.invalidate(); noticeTimer = nil
        speechTask?.cancel(); speechTask = nil
        speechQueue.removeAll()
        pending.removeAll()
        translators.values.forEach { $0.cancel() }
        translators.removeAll()
        output.stop()
        if let microphone {
            self.microphone = nil
            Task { await microphone.stop() }
        }
        if let transcriber = setup?.transcriber {
            Task { await transcriber.stop() }
        }
        setup?.stream.manager.notice = nil
        setup = nil
        phase = .idle
        Log.info(.speak, "Speak stopped")
    }

    // MARK: - The key

    func beginHold() {
        guard running, ready, let setup, !gate.isHolding else { return }
        if phase == .speaking { interruptSpeech() }
        gate.setHolding(true)
        holdStarted = Date()
        phase = .listening
        let their = setup.theirLanguage()?.displayName ?? "…"
        show("Listening · \(setup.myLanguage.displayName) → \(their)")
        holdCeiling?.invalidate()
        holdCeiling = Timer.scheduledTimer(withTimeInterval: Self.maximumHold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endHold() }
        }
        Log.info(.speak, "Hold began")
    }

    func endHold() {
        guard running, gate.isHolding, let setup else { return }
        gate.setHolding(false)
        holdCeiling?.invalidate(); holdCeiling = nil
        let held = holdStarted.map { Date().timeIntervalSince($0) } ?? 0
        holdStarted = nil
        Log.info(.speak, "Hold ended after \(String(format: "%.1f", held)) s")
        setup.transcriber.flush()
        phase = .working
        show("Translating…")
        // Whisper on a few seconds of speech takes well under a second; if
        // nothing has come back by then there was nothing to hear.
        catchTimer?.invalidate()
        catchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .working, self.pending.isEmpty, self.speechQueue.isEmpty else { return }
                self.show("Didn't catch that", for: 2)
                self.phase = .idle
            }
        }
    }

    /// Tap-to-talk: one press starts, the next stops.
    func toggleHold() {
        gate.isHolding ? endHold() : beginHold()
    }

    func interruptSpeech() {
        speechTask?.cancel()
        speechTask = nil
        speechQueue.removeAll()
        output.interrupt()
        if phase == .speaking { phase = .idle; show(nil) }
    }

    /// Audio thread. Buffers are only looked at while the key is down.
    nonisolated func receive(_ buffer: AVAudioPCMBuffer) {
        guard let transcriber = gate.transcriberIfHolding else { return }
        transcriber.receive(buffer)
    }

    // MARK: - Pipeline

    private func heard(_ said: String) {
        guard running, let setup else { return }
        catchTimer?.invalidate(); catchTimer = nil
        guard let their = setup.theirLanguage() else {
            show("Relay hasn't heard them yet. Pick their language in Settings → Speak, or wait for them to talk.", for: 5)
            phase = .idle
            return
        }
        let manager = setup.stream.manager
        manager.setOriginal(said, you: true)
        pending.append((said, their))
        phase = .working
        show("Translating…")
        do {
            try translator(to: their).translate(said)
        } catch {
            onWarning?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            pending.removeLast()
            phase = .idle
        }
    }

    private func translator(to language: Language) throws -> TextTranslating {
        if let existing = translators[language] { return existing }
        guard let setup else { throw EngineError.setupFailed("Speak is not running.") }
        let translator = try setup.makeTranslator(setup.myLanguage, language)
        translator.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.setup?.stream.manager.updatePartial(text, you: true) }
        }
        translator.onFinal = { [weak self] text in
            MainActor.assumeIsolated { self?.translated(text) }
        }
        translator.onFatalError = { [weak self] message in
            MainActor.assumeIsolated { self?.onWarning?(message) }
        }
        translator.onTrouble = { [weak self] message in
            MainActor.assumeIsolated { self?.onWarning?(message.map { "Speak isn't working. \($0)" }) }
        }
        translators[language] = translator
        return translator
    }

    private func translated(_ text: String) {
        guard running, let setup else { return }
        let waiting = pending.isEmpty ? (said: "", language: setup.myLanguage) : pending.removeFirst()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        setup.stream.manager.complete(trimmed, original: waiting.said, you: true)
        guard !trimmed.isEmpty else {
            if pending.isEmpty, speechQueue.isEmpty, speechTask == nil { phase = .idle; show(nil) }
            return
        }
        onLine?(waiting.said, trimmed, waiting.language)
        speechQueue.append((trimmed, waiting.language))
        speakNext()
    }

    private func speakNext() {
        guard speechTask == nil, let setup, !speechQueue.isEmpty else { return }
        let next = speechQueue.removeFirst()
        phase = .speaking
        show("Speaking…")
        gate.setSpeaking(true)
        speechTask = Task { [weak self] in
            var spoke = false
            do {
                try await self?.play(next.text, in: next.language, with: setup.synthesizer)
                spoke = true
            } catch SpeechError.cancelled {
                return
            } catch {
                Log.error(.speak, "\(setup.synthesizer.name) voice failed: \(error.localizedDescription)")
                if let fallback = setup.fallback {
                    self?.onWarning?("\(error.localizedDescription) Using the Mac's voice instead.")
                    do {
                        try await self?.play(next.text, in: next.language, with: fallback)
                        spoke = true
                    } catch {
                        self?.onWarning?(error.localizedDescription)
                    }
                } else {
                    self?.onWarning?(error.localizedDescription)
                }
            }
            guard let self, !Task.isCancelled else { return }
            if spoke {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    self.output.whenDrained { done.resume() }
                }
            }
            self.finishedSpeaking()
        }
    }

    private func play(_ text: String, in language: Language, with synthesizer: SpeechSynthesizing) async throws {
        let started = Date()
        var first = true
        for try await buffer in synthesizer.synthesize(text, in: language) {
            if first {
                first = false
                Log.info(.speak, "\(synthesizer.name): first buffer after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            }
            output.enqueue(buffer)
        }
    }

    private func finishedSpeaking() {
        speechTask = nil
        // Leave the incoming side muted a moment longer: the room is still
        // ringing with the last word.
        gate.setSpeaking(false, tail: 0.3)
        if !speechQueue.isEmpty {
            speakNext()
        } else if phase == .speaking {
            phase = pending.isEmpty ? .idle : .working
            show(pending.isEmpty ? nil : "Translating…")
        }
    }

    #if DEBUG
    /// Runs one utterance from a file through the pipeline as if it had been
    /// spoken while the key was held. For checking the whole chain from the
    /// command line; nothing in the app calls it.
    func selfTest(file url: URL) {
        guard running, let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else {
            Log.error(.speak, "Self-test: could not read \(url.lastPathComponent)")
            return
        }
        Log.info(.speak, "Self-test: feeding \(url.lastPathComponent) (\(String(format: "%.1f", Double(file.length) / file.processingFormat.sampleRate)) s)")
        beginHold()
        // 20 ms slices, like the microphone delivers.
        let slice = AVAudioFrameCount(file.processingFormat.sampleRate / 50)
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let count = min(slice, buffer.frameLength - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                if let src = buffer.floatChannelData?[channel], let dst = piece.floatChannelData?[channel] {
                    dst.update(from: src + Int(offset), count: Int(count))
                }
            }
            piece.frameLength = count
            receive(piece)
            offset += count
        }
        endHold()
    }
    #endif

    // MARK: - HUD

    private func show(_ text: String?, for seconds: TimeInterval? = nil) {
        noticeTimer?.invalidate(); noticeTimer = nil
        setup?.stream.manager.notice = text
        if let seconds {
            noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.setup?.stream.manager.notice == text else { return }
                    self.setup?.stream.manager.notice = nil
                }
            }
        }
    }

    // MARK: - Audio-thread state

    /// The little that the audio thread needs to know, behind a lock, so the
    /// main-actor controller never has to be touched from there.
    final class Gate {
        private let lock = NSLock()
        private var holding = false
        private var transcriber: WhisperTranscriptionService?
        private var speakingUntil = Date.distantPast

        var isHolding: Bool { lock.withLock { holding } }

        /// The transcriber to feed, only while the key is down.
        var transcriberIfHolding: WhisperTranscriptionService? {
            lock.withLock { holding ? transcriber : nil }
        }

        /// While Relay itself is talking, the microphone hears it; the
        /// incoming side should not subtitle it.
        var mutesIncoming: Bool { lock.withLock { Date() < speakingUntil } }

        func setHolding(_ value: Bool) { lock.withLock { holding = value } }
        func setTranscriber(_ value: WhisperTranscriptionService?) { lock.withLock { transcriber = value } }
        func setSpeaking(_ speaking: Bool, tail: TimeInterval = 0) {
            lock.withLock { speakingUntil = speaking ? .distantFuture : Date().addingTimeInterval(tail) }
        }
    }
}
