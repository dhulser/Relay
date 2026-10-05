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
///
/// Two lifetimes live here. The *call line* (the output engine, the
/// microphone pass-through and the Relay Voice device) stays up for as long
/// as Speak is set to the call, so a call app that picked Relay Voice as its
/// microphone keeps hearing you between sessions. The *session* (recogniser,
/// translators) starts and stops with Relay's listening.
@MainActor
final class SpokenReplyController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        /// Recognising or translating; from the outside the same wait.
        case working
        /// A translation is waiting for the user to send or drop it.
        case confirming
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
        /// Show the translation and wait for a tap before speaking it.
        let confirmBeforeSpeaking: Bool
        /// The subtitle stream the You line goes to.
        let stream: SubtitleStream
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var running = false
    /// True once the recogniser and the output are up and a hold will be
    /// heard. Loading the speech model takes a few seconds the first time.
    @Published private(set) var ready = false
    /// Whether the Relay Voice device exists right now.
    @Published private(set) var callLineUp = false
    /// Whether some other process is reading Relay Voice: the nearest thing
    /// to "Zoom has picked it". Nil while the device does not exist.
    @Published private(set) var callAppIsUsingDevice: Bool?

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
    private let device = RelayVoiceDevice()
    private var callLine = false
    private var callMonitor: RelayVoiceDevice.Monitor = .silent
    private var devicePoll: Timer?
    private var translators: [Language: TextTranslating] = [:]
    /// What was said, waiting for its translation, with the language it is
    /// being translated into.
    private var pending: [(said: String, language: Language)] = []
    private var speechQueue: [(text: String, language: Language)] = []
    private var speechTask: Task<Void, Never>?
    private var awaitingConfirmation: (text: String, language: Language, said: String)?
    private var holdStarted: Date?
    private var holdCeiling: Timer?
    private var catchTimer: Timer?
    private var noticeTimer: Timer?

    /// Nobody can usefully hold for longer; a lost key-up would otherwise
    /// record for ever.
    static let maximumHold: TimeInterval = 60
    /// A press shorter than this while a translation waits means "send it",
    /// not "say something else".
    static let confirmTap: TimeInterval = 0.4

    // MARK: - The call line

    /// Brings Relay Voice up or down. Up: the output runs, the microphone is
    /// copied through it, and the device exists for call apps to pick.
    func setCallLine(_ on: Bool, monitor: RelayVoiceDevice.Monitor, hearOriginal: Bool) {
        gate.setHearOriginal(hearOriginal)
        if on, callLine, monitor != callMonitor {
            // Only the tap's mute differs; rebuild it.
            device.destroy()
            callMonitor = monitor
            createDeviceWhenReady()
            return
        }
        guard on != callLine else { return }
        callLine = on
        callMonitor = monitor
        gate.setPassThrough(on)
        if on {
            Task { await bringCallLineUp() }
        } else {
            takeCallLineDown()
        }
    }

    private func bringCallLineUp() async {
        do {
            try output.start()
            if microphone == nil {
                let microphone = MicrophoneCaptureService()
                microphone.onAudioBuffer = { [weak self] buffer in self?.receive(buffer) }
                microphone.onError = { [weak self] error in
                    MainActor.assumeIsolated { self?.onWarning?(error.localizedDescription) }
                }
                try await microphone.start()
                self.microphone = microphone
            }
        } catch {
            onWarning?("Relay Voice couldn't start. \(error.localizedDescription)")
            callLine = false
            gate.setPassThrough(false)
            return
        }
        guard callLine else { return }
        createDeviceWhenReady()
    }

    /// Core Audio gives a process an audio object only once it has done IO,
    /// so the device may have to wait a moment for the output to render.
    private func createDeviceWhenReady(attempt: Int = 0) {
        guard callLine, !device.exists else { return }
        do {
            try device.create(monitor: callMonitor)
            callLineUp = true
            startDevicePoll()
        } catch RelayVoiceDevice.DeviceError.noProcessObject where attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.createDeviceWhenReady(attempt: attempt + 1)
            }
        } catch {
            onWarning?(error.localizedDescription)
        }
    }

    private func takeCallLineDown() {
        devicePoll?.invalidate(); devicePoll = nil
        device.destroy()
        callLineUp = false
        callAppIsUsingDevice = nil
        output.resetPassThrough()
        if !running {
            output.stop()
            if let microphone {
                self.microphone = nil
                Task { await microphone.stop() }
            }
        }
    }

    private func startDevicePoll() {
        devicePoll?.invalidate()
        devicePoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.device.exists else { return }
                let inUse = self.device.isInUseByAnotherApp
                if inUse != self.callAppIsUsingDevice {
                    self.callAppIsUsingDevice = inUse
                    Log.info(.speak, inUse ? "A call app is reading Relay Voice" : "No app is reading Relay Voice")
                }
            }
        }
    }

    // MARK: - Session

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

        if setup.ownMicrophone, microphone == nil {
            let microphone = MicrophoneCaptureService()
            microphone.onAudioBuffer = { [weak self] buffer in self?.receive(buffer) }
            microphone.onError = { [weak self] error in
                MainActor.assumeIsolated { self?.onWarning?(error.localizedDescription) }
            }
            try await microphone.start()
            self.microphone = microphone
        }
        gate.setTranscriber(setup.transcriber)
        ready = true
        Log.info(.speak, "Speak ready: \(setup.myLanguage.displayName) → \(setup.theirLanguage()?.displayName ?? "their language, once heard"), voice \(setup.synthesizer.name), to \(callLine ? "Relay Voice" : "the speakers")")
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
        awaitingConfirmation = nil
        translators.values.forEach { $0.cancel() }
        translators.removeAll()
        output.interrupt()
        gate.setSpeaking(false)
        if !callLine {
            output.stop()
            if let microphone {
                self.microphone = nil
                Task { await microphone.stop() }
            }
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
        if phase != .confirming {
            phase = .listening
            let their = setup.theirLanguage()?.displayName ?? "…"
            show("Listening · \(setup.myLanguage.displayName) → \(their)")
        }
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

        // A tap while a translation waits sends it; a real hold replaces it.
        if awaitingConfirmation != nil {
            if held < Self.confirmTap {
                confirm()
                return
            }
            awaitingConfirmation = nil
            setup.stream.manager.complete("", you: true)
        }

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

    /// Tap-to-talk: one press starts, the next stops. While a translation
    /// waits, a press sends it.
    func toggleHold() {
        if awaitingConfirmation != nil, !gate.isHolding { confirm(); return }
        gate.isHolding ? endHold() : beginHold()
    }

    /// Speak the translation that is waiting.
    func confirm() {
        guard let waiting = awaitingConfirmation else { return }
        awaitingConfirmation = nil
        onLine?(waiting.said, waiting.text, waiting.language)
        speechQueue.append((waiting.text, waiting.language))
        speakNext()
    }

    /// Throw the waiting translation away.
    func discard() {
        guard awaitingConfirmation != nil else { return }
        awaitingConfirmation = nil
        setup?.stream.manager.complete("", you: true)
        phase = .idle
        show(nil)
    }

    func interruptSpeech() {
        speechTask?.cancel()
        speechTask = nil
        speechQueue.removeAll()
        output.interrupt()
        gate.setSpeaking(false)
        if phase == .speaking { phase = .idle; show(nil) }
    }

    /// Audio thread. While the key is down the buffer is for the recogniser;
    /// otherwise, on a call, it is copied through to Relay Voice.
    nonisolated func receive(_ buffer: AVAudioPCMBuffer) {
        let route = gate.route
        if let transcriber = route.transcriber { transcriber.receive(buffer) }
        if route.passThrough { output.passThrough(buffer) }
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
        guard !trimmed.isEmpty else {
            setup.stream.manager.complete("", you: true)
            if pending.isEmpty, speechQueue.isEmpty, speechTask == nil { phase = .idle; show(nil) }
            return
        }
        if setup.confirmBeforeSpeaking {
            // Leave it on screen as the in-flight line until they decide.
            setup.stream.manager.updatePartial(trimmed, you: true)
            awaitingConfirmation = (trimmed, waiting.language, waiting.said)
            phase = .confirming
            show("Tap the key to say it, or hold to say something else")
            return
        }
        setup.stream.manager.complete(trimmed, original: waiting.said, you: true)
        onLine?(waiting.said, trimmed, waiting.language)
        speechQueue.append((trimmed, waiting.language))
        speakNext()
    }

    private func speakNext() {
        guard speechTask == nil, let setup, !speechQueue.isEmpty else { return }
        let next = speechQueue.removeFirst()
        if phase == .confirming {
            setup.stream.manager.complete(next.text, original: awaitingConfirmation?.said, you: true)
        }
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
        // Long enough to count as a hold rather than a confirm tap.
        holdStarted = Date().addingTimeInterval(-1)
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
        struct Route {
            let transcriber: WhisperTranscriptionService?
            let passThrough: Bool
        }

        private let lock = NSLock()
        private var holding = false
        private var transcriber: WhisperTranscriptionService?
        private var speakingUntil = Date.distantPast
        private var passThrough = false
        private var hearOriginal = false

        var isHolding: Bool { lock.withLock { holding } }

        /// Where a microphone buffer goes right now. Held: to the recogniser,
        /// and through to the call only if they are meant to hear the
        /// original too. Not held: through to the call when on one.
        var route: Route {
            lock.withLock {
                Route(transcriber: holding ? transcriber : nil,
                      passThrough: passThrough && (!holding || hearOriginal))
            }
        }

        /// While Relay itself is talking, the microphone hears it; the
        /// incoming side should not subtitle it.
        var mutesIncoming: Bool { lock.withLock { Date() < speakingUntil } }

        func setHolding(_ value: Bool) { lock.withLock { holding = value } }
        func setTranscriber(_ value: WhisperTranscriptionService?) { lock.withLock { transcriber = value } }
        func setPassThrough(_ value: Bool) { lock.withLock { passThrough = value } }
        func setHearOriginal(_ value: Bool) { lock.withLock { hearOriginal = value } }
        func setSpeaking(_ speaking: Bool, tail: TimeInterval = 0) {
            lock.withLock { speakingUntil = speaking ? .distantFuture : Date().addingTimeInterval(tail) }
        }
    }
}
