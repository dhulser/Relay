import Foundation
import AVFoundation

/// Streams captured audio to the OpenAI Realtime translations endpoint, which
/// translates speech to text in a single hop.
///
/// The API key is read from the Keychain and held only in memory. It is never
/// logged, and neither are base64 audio payloads.
final class OpenAIRealtimeService: NSObject, TranslationEngine {

    // TranslationEngine — callbacks are delivered on the main queue.
    var onStateChange: ((EngineState) -> Void)?
    // The Realtime model returns text with no alignment to our audio, so there
    // is nothing to hang a speaker label on — always nil.
    var onPartialTranslation: ((String, Int?) -> Void)?
    var onFinalTranslation: ((String, Int?) -> Void)?
    var onFatalError: ((String) -> Void)?
    /// The source-language transcript, as it is heard. Whole utterance so far
    /// on each delta, then the finished text.
    var onSourceTranscript: ((String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    private var apiKey = ""
    private var sourceLanguage: SourceLanguageSetting = .auto
    private var targetLanguage: Language = .english

    /// True between `start()` and `stop()`. Gates reconnection so a deliberate
    /// stop never triggers a retry.
    private var shouldRun = false
    private var reconnectAttempt = 0
    private var reconnectScheduled = false
    private var loggedFirstAudioSend = false
    private var unknownEventTypesSeen = Set<String>()
    private var loggedRawSample = false

    /// The utterance being spoken right now, accumulated from deltas so the
    /// engine emits whole-utterance text rather than fragments.
    private var currentUtterance = ""
    /// What the transcription model has heard of the current utterance.
    private var currentSource = ""

    private let converter = AudioConverter(target: AudioConverter.openAIRealtimeFormat)

    /// Batch audio into ~100 ms chunks. Sending each 20 ms buffer as its own
    /// WebSocket frame is needless overhead; 100 ms is still well inside the
    /// latency budget for live captions.
    private static let chunkBytes = Int(24_000 * 0.1) * MemoryLayout<Int16>.size
    private var pendingChunk = Data()
    private var chunksSent = 0

    private let queue = DispatchQueue(label: "co.kevel.Relay.realtime")

    private var state: EngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            let newState = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(newState) }
        }
    }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Lifecycle

    func start(source: SourceLanguageSetting, target: Language) throws {
        guard let key = KeychainService.loadAPIKey(for: .openai) else {
            throw EngineError.missingAPIKey(.openai)
        }
        queue.async {
            self.apiKey = key
            self.sourceLanguage = source
            self.targetLanguage = target
            self.shouldRun = true
            self.reconnectAttempt = 0
            self.currentUtterance = ""
            self.currentSource = ""
            self.pendingChunk.removeAll(keepingCapacity: true)
            self.chunksSent = 0
            self.converter.reset()
            self.openSocket()
        }
    }

    func stop() {
        queue.async {
            guard self.shouldRun else { return }
            self.shouldRun = false
            self.reconnectScheduled = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.state = .idle
            Log.info(.realtime, "Disconnected")
        }
    }

    private func openSocket() {
        guard shouldRun else { return }

        loggedFirstAudioSend = false
        state = state == .idle ? .connecting : .reconnecting
        Log.info(.realtime, reconnectAttempt == 0 ? "Connecting" : "Reconnecting (attempt \(reconnectAttempt))")

        var request = URLRequest(url: RealtimeAPI.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveNext()
    }

    // MARK: - Sending

    /// Convert to 24 kHz mono PCM16 and send in fixed-size chunks. Audio that
    /// arrives while we're reconnecting is dropped rather than queued — stale
    /// audio is worse than no audio for live subtitles.
    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = converter.convertToPCM16Data(buffer) else { return }

        queue.async {
            self.pendingChunk.append(pcm)
            while self.pendingChunk.count >= Self.chunkBytes {
                let chunk = Data(self.pendingChunk.prefix(Self.chunkBytes))
                self.pendingChunk.removeFirst(Self.chunkBytes)
                self.send(chunk: chunk)
            }
        }
    }

    private func send(chunk: Data) {
        guard state == .ready, let task else { return }

        chunksSent += 1
        if chunksSent <= 3 {
            Log.info(.audio, "Chunk \(chunksSent): \(chunk.count) bytes (100 ms)")
        }

        let event = AudioAppendEvent(audio: chunk.base64EncodedString())
        guard let json = Self.encode(event) else { return }

        if !loggedFirstAudioSend {
            loggedFirstAudioSend = true
            Log.info(.realtime, "Sending audio")
        }

        task.send(.string(json)) { error in
            guard let error else { return }
            Log.error(.realtime, "Audio send failed: \(error.localizedDescription)")
        }
    }

    private func sendSessionUpdate() {
        guard let task, let json = Self.encode(SessionUpdateEvent(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )) else { return }

        let description = sourceLanguage.language == nil
            ? "auto-detect → \(targetLanguage.displayName)"
            : "\(sourceLanguage.displayName) → \(targetLanguage.displayName)"
        task.send(.string(json)) { error in
            if let error {
                Log.error(.realtime, "Session update failed: \(error.localizedDescription)")
                return
            }
            Log.info(.realtime, "Session configured (\(description))")
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            Log.error(.realtime, "Could not encode outbound event")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Receiving

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async { self.handleTransportFailure(error) }
            case .success(let message):
                self.queue.async {
                    switch message {
                    case .string(let text): self.handle(rawJSON: Data(text.utf8))
                    case .data(let data): self.handle(rawJSON: data)
                    @unknown default: break
                    }
                    self.receiveNext()
                }
            }
        }
    }

    private func handle(rawJSON: Data) {
        // Every inbound frame is logged once per distinct event type. A frame we
        // can't decode used to vanish silently, which made an empty session
        // indistinguishable from a schema mismatch.
        if let text = String(data: rawJSON, encoding: .utf8) {
            let head = String(text.prefix(240))
            if !loggedRawSample {
                loggedRawSample = true
                Log.info(.realtime, "first inbound frame: \(head)")
            }
        }

        guard let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: rawJSON) else {
            let head = String(String(data: rawJSON, encoding: .utf8)?.prefix(240) ?? "<binary>")
            Log.error(.realtime, "could not decode an inbound frame")
            Log.content(.realtime, head)
            return
        }

        if unknownEventTypesSeen.insert(event.type).inserted {
            Log.info(.realtime, "event: \(event.type)")
        }

        switch RealtimeEventKind(from: event) {
        case .sessionReady:
            break // logged on send; the echo back is noise

        case .translatedDelta(let text):
            guard !text.isEmpty else { return }
            currentUtterance += text
            // The translation model streams continuously and only rarely marks
            // an utterance done, so without this everything piles into one
            // ever-growing paragraph. Completed sentences become their own
            // caption lines.
            flushCompletedSentences()

            let running = currentUtterance.trimmingCharacters(in: .whitespaces)
            guard !running.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onPartialTranslation?(running, nil) }

        case .translatedCompleted(let text):
            let final = text.isEmpty ? currentUtterance : text
            currentUtterance = ""
            guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onFinalTranslation?(final, nil) }

        case .sourceTranscriptDelta(let text):
            currentSource += text
            let heard = currentSource
            DispatchQueue.main.async { [weak self] in self?.onSourceTranscript?(heard) }

        case .sourceTranscript(let text):
            let heard = text.isEmpty ? currentSource : text
            currentSource = ""
            guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onSourceTranscript?(heard) }

        case .speechStarted:
            Log.info(.realtime, "Speech started")

        case .speechStopped:
            Log.info(.realtime, "Speech stopped")

        case .audioChunk:
            break // we asked for subtitles, not dubbing

        case .error(let message):
            Log.error(.realtime, message)
            // A rejected key or model is not worth retrying.
            if Self.isFatal(message) { fail(with: message) }

        case .other:
            break // already logged above by type
        }
    }

    /// Emits every complete sentence sitting in the buffer as a finished line,
    /// leaving the trailing fragment as the in-flight utterance.
    private func flushCompletedSentences() {
        while let cut = Self.sentenceEnd(in: currentUtterance) {
            let sentence = String(currentUtterance[..<cut])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentUtterance = String(currentUtterance[cut...])
            guard !sentence.isEmpty else { continue }
            DispatchQueue.main.async { [weak self] in self?.onFinalTranslation?(sentence, nil) }
        }

        // Someone talking without punctuation would otherwise never get a line
        // break, so fall back to cutting at a word boundary.
        guard currentUtterance.count > Self.maximumLineCharacters else { return }
        let limit = currentUtterance.index(currentUtterance.startIndex,
                                           offsetBy: Self.maximumLineCharacters)
        guard let space = currentUtterance[..<limit].lastIndex(of: " ") else { return }

        let chunk = String(currentUtterance[..<space]).trimmingCharacters(in: .whitespaces)
        currentUtterance = String(currentUtterance[currentUtterance.index(after: space)...])
        guard !chunk.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onFinalTranslation?(chunk, nil) }
    }

    static let maximumLineCharacters = 160

    /// Index just past the end of the first complete sentence, or nil.
    /// A terminator must be followed by whitespace so decimals and initials
    /// ("3.5", "J. Smith") don't split a line.
    static func sentenceEnd(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
        var index = text.startIndex
        while index < text.endIndex {
            defer { index = text.index(after: index) }
            guard terminators.contains(text[index]) else { continue }
            let next = text.index(after: index)
            guard next < text.endIndex else { continue }
            if text[next].isWhitespace { return next }
        }
        return nil
    }

    private static func isFatal(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("api key")
            || lowered.contains("unauthorized")
            || lowered.contains("invalid_api_key")
            || lowered.contains("does not have access")
            || lowered.contains("model_not_found")
    }

    // MARK: - Failure handling

    private func handleTransportFailure(_ error: Error) {
        guard shouldRun else { return }

        if let status = (task?.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            fail(with: "OpenAI rejected the API key (HTTP \(status)). Check it in Settings.")
            return
        }

        Log.error(.realtime, "Connection lost: \(error.localizedDescription)")
        scheduleReconnect()
    }

    private func fail(with message: String) {
        shouldRun = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .idle
        Log.error(.realtime, message)
        DispatchQueue.main.async { [weak self] in self?.onFatalError?(message) }
    }

    /// Exponential backoff with jitter, capped at 30 s.
    private func scheduleReconnect() {
        guard shouldRun, !reconnectScheduled else { return }
        reconnectScheduled = true
        state = .reconnecting

        reconnectAttempt += 1
        let backoff = min(pow(2.0, Double(reconnectAttempt - 1)) * 0.5, 30)
        let delay = backoff + Double.random(in: 0...0.3)
        Log.info(.realtime, "Reconnecting in \(String(format: "%.1f", delay))s")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.openSocket()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAIRealtimeService: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async {
            guard self.shouldRun else { return }
            self.reconnectAttempt = 0
            self.state = .ready
            Log.info(.realtime, "Connected")
            self.sendSessionUpdate()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard self.shouldRun else { return }
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Log.error(.realtime, "Socket closed (code \(closeCode.rawValue)) \(detail)")
            self.scheduleReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        queue.async { self.handleTransportFailure(error) }
    }
}
