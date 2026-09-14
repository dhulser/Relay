import Foundation

/// Translates finished utterances with an OpenAI text model via the Chat
/// Completions API, streamed so subtitles appear as they're produced.
///
/// Same shape as `ClaudeTranslator` — only the wire format differs.
final class OpenAITextTranslator: TextTranslating {

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFatalError: ((String) -> Void)?
    var onTrouble: ((String?) -> Void)?

    private let apiKey: String
    private let model: OpenAITextModel
    private let systemPrompt: String
    private let session: URLSession

    /// Utterances translate one at a time so subtitles can't arrive out of
    /// order. Every task still running is kept so `cancel()` stops all of them.
    private var inFlight: [Task<Void, Never>] = []

    init(apiKey: String, model: OpenAITextModel, source: SourceLanguageSetting, target: Language) {
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
        if inFlight.count > 8 { inFlight.removeFirst(inFlight.count - 8) }
    }

    func cancel() {
        inFlight.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private func stream(_ text: String) async {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONEncoder().encode(
                ChatCompletionRequest(model: model, systemPrompt: systemPrompt, userText: text)
            )
        } catch {
            Log.error(.openai, "Could not encode request: \(error.localizedDescription)")
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                await handleHTTPError(status: http.statusCode, bytes: bytes)
                return
            }

            var translation = ""
            reading: for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                switch Self.interpret(line) {
                case .text(let chunk):
                    translation += chunk
                    let running = translation
                    await MainActor.run { self.onPartial?(running) }
                case .done:
                    break reading
                case .nothing:
                    continue
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
            Log.error(.openai, "Request failed: \(error.localizedDescription)")
            await noteFailure(error.localizedDescription)
        }
    }

    /// What one line of the SSE stream means to us.
    enum Signal: Equatable {
        case text(String)
        case done
        case nothing
    }

    /// Pure, so the wire handling can be tested without a network.
    static func interpret(_ line: String) -> Signal {
        guard line.hasPrefix("data: ") else { return .nothing }
        let payload = line.dropFirst(6)
        if payload == "[DONE]" { return .done }
        guard let event = try? JSONDecoder().decode(ChatCompletionChunk.self, from: Data(payload.utf8)),
              let chunk = event.choices.first?.delta.content, !chunk.isEmpty
        else { return .nothing }
        return .text(chunk)
    }

    private func handleHTTPError(status: Int, bytes: URLSession.AsyncBytes) async {
        var body = ""
        do {
            for try await line in bytes.lines { body += line }
        } catch {
            // Body is best-effort; the status code is what matters below.
        }
        let message = (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(body.utf8)))?
            .error.message ?? "HTTP \(status)"

        switch status {
        case 401, 403:
            await reportFatal("OpenAI rejected the API key (HTTP \(status)). Check it in Settings.")
        case 404:
            await reportFatal("Model \(model.rawValue) is not available to this account.")
        case 429:
            Log.error(.openai, "HTTP 429, dropping this utterance: \(message)")
            await noteFailure(message)
        default:
            Log.error(.openai, "HTTP \(status): \(message)")
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

    private func reportFatal(_ message: String) async {
        Log.error(.openai, message)
        await MainActor.run { self.onFatalError?(message) }
    }
}

// MARK: - Wire types

struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let stream: Bool
    let messages: [Message]
    let max_completion_tokens: Int

    init(model: OpenAITextModel, systemPrompt: String, userText: String) {
        self.model = model.rawValue
        self.stream = true
        self.messages = [
            Message(role: "system", content: systemPrompt),
            Message(role: "user", content: userText),
        ]
        // Subtitle-length output; a spoken utterance never needs more.
        self.max_completion_tokens = 1024
    }
}

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

struct OpenAIErrorResponse: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
