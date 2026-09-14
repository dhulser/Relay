import Foundation

/// Translates finished utterances with the Claude Messages API.
///
/// Swift has no official Anthropic SDK, so this talks raw HTTP. Responses are
/// streamed (SSE) so subtitles appear as the translation is produced rather
/// than after it completes.
///
/// Each utterance is an independent request with no conversation history:
/// translation doesn't need it, and sending it would add latency and cost to
/// every line. The API key is never logged.
final class ClaudeTranslator: TextTranslating {

    /// The translation so far for the utterance in flight.
    var onPartial: ((String) -> Void)?

    /// The finished translation of an utterance.
    var onFinal: ((String) -> Void)?

    /// Unrecoverable — bad key, refused model.
    var onFatalError: ((String) -> Void)?
    var onTrouble: ((String?) -> Void)?

    private let apiKey: String
    private let model: ClaudeModel
    private let systemPrompt: String
    private let session: URLSession

    /// Utterances are translated one at a time so subtitles can't arrive out of
    /// order when two land close together. Every task still running is kept,
    /// so `cancel()` can stop all of them rather than only the newest.
    private var inFlight: [Task<Void, Never>] = []

    init(apiKey: String, model: ClaudeModel, source: SourceLanguageSetting, target: Language) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = TranslationPrompt.instructions(source: source, target: target)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func translate(_ utterance: String) {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let previous = inFlight.last
        inFlight.append(Task { [weak self] in
            _ = await previous?.result
            guard let self, !Task.isCancelled else { return }
            await self.stream(text)
        })
        // Tasks complete in order, so only the tail can still be running.
        if inFlight.count > 8 { inFlight.removeFirst(inFlight.count - 8) }
    }

    func cancel() {
        inFlight.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Streaming request

    private func stream(_ text: String) async {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONEncoder().encode(
                MessagesRequest(model: model, systemPrompt: systemPrompt, userText: text)
            )
        } catch {
            Log.error(.claude, "Could not encode request: \(error.localizedDescription)")
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await handleHTTPError(status: http.statusCode, bytes: bytes)
                return
            }

            var translation = ""
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                switch Self.interpret(line) {
                case .text(let chunk):
                    translation += chunk
                    let running = translation
                    await MainActor.run { self.onPartial?(running) }
                case .refusal:
                    Log.error(.claude, "Claude declined to translate this utterance")
                case .error(let message):
                    Log.error(.claude, message)
                    if Self.isFatal(message) { await reportFatal(message) }
                case .nothing:
                    break
                }
            }

            let final = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty else { return }
            guard !Task.isCancelled else { return }
            Log.content(.translation, final)
            await noteSuccess()
            await MainActor.run { self.onFinal?(final) }

        } catch {
            guard !Task.isCancelled else { return }
            Log.error(.claude, "Request failed: \(error.localizedDescription)")
            await noteFailure(error.localizedDescription)
        }
    }

    private func handleHTTPError(status: Int, bytes: URLSession.AsyncBytes) async {
        var body = ""
        do {
            for try await line in bytes.lines { body += line }
        } catch {
            // Body is best-effort; the status code is what matters below.
        }

        let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: Data(body.utf8)))?.error.message
            ?? "HTTP \(status)"

        switch status {
        case 401, 403:
            await reportFatal("Anthropic rejected the API key (HTTP \(status)). Check it in Settings.")
        case 404:
            await reportFatal("Model \(model.rawValue) is not available to this account.")
        case 429:
            Log.error(.claude, "Rate limited — dropping this utterance")
            await noteFailure(message)
        default:
            Log.error(.claude, "HTTP \(status): \(message)")
            await noteFailure(message)
        }
    }

    // MARK: - Trouble

    /// Failures in a row. One is bad luck; two means the pipeline is broken
    /// and the user should be told rather than left watching "Listening".
    private var consecutiveFailures = 0

    private func noteFailure(_ message: String) async {
        consecutiveFailures += 1
        guard consecutiveFailures >= 2 else { return }
        await MainActor.run { self.onTrouble?(message) }
    }

    private func noteSuccess() async {
        guard consecutiveFailures > 0 else { return }
        consecutiveFailures = 0
        await MainActor.run { self.onTrouble?(nil) }
    }

    /// What one line of the SSE stream means to us.
    enum Signal: Equatable {
        case text(String)
        case refusal
        case error(String)
        case nothing
    }

    /// Pure, so the wire handling can be tested without a network.
    static func interpret(_ line: String) -> Signal {
        guard line.hasPrefix("data: ") else { return .nothing }
        let payload = Data(line.dropFirst(6).utf8)
        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: payload) else { return .nothing }

        switch event.type {
        case "content_block_delta":
            guard let chunk = event.delta?.text, !chunk.isEmpty else { return .nothing }
            return .text(chunk)
        case "message_delta":
            return event.delta?.stop_reason == "refusal" ? .refusal : .nothing
        case "error":
            return .error(event.error?.message ?? "Unknown API error")
        default:
            return .nothing
        }
    }

    static func isFatal(_ message: String) -> Bool {
        // Anthropic spells it "x-api-key" in the 401 body and "api key" in
        // prose; both mean the key is wrong and retrying won't help.
        let lowered = message.lowercased()
        return lowered.contains("authentication")
            || lowered.contains("api key")
            || lowered.contains("api-key")
            || lowered.contains("api_key")
            || lowered.contains("permission")
            || lowered.contains("not_found")
    }

    private func reportFatal(_ message: String) async {
        Log.error(.claude, message)
        await MainActor.run { self.onFatalError?(message) }
    }
}
