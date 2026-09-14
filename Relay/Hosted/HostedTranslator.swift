import Foundation

/// Local mode through Relay Hosted: the utterance goes to the Relay API,
/// which owns the prompt and the model and streams OpenAI's reply back
/// unchanged, so the parsing is the same as bring-your-own-key.
final class HostedTranslator: TextTranslating {

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFatalError: ((String) -> Void)?
    var onTrouble: ((String?) -> Void)?

    private let token: String
    private let target: Language
    private let source: Language?
    private let session: URLSession
    private var inFlight: [Task<Void, Never>] = []

    init(token: String, source: SourceLanguageSetting, target: Language) {
        self.token = token
        self.target = target
        self.source = source.language
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

    private struct Body: Encodable { let text: String; let target: String; let source: String? }

    private func stream(_ text: String) async {
        var request = URLRequest(url: HostedAccount.baseURL.appendingPathComponent("/v1/translate"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONEncoder().encode(Body(text: text, target: target.displayName, source: source?.displayName))

        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var body = ""
                for try await line in bytes.lines { body += line }
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: Data(body.utf8)))?.error.message
                    ?? "Relay Hosted returned HTTP \(status)."
                switch status {
                case 401, 402: await reportFatal(message)   // signed out, cap reached, subscription lapsed
                case 429: Log.error(.openai, "Hosted: HTTP 429, dropping this utterance: \(message)"); await noteFailure(message)
                default: Log.error(.openai, "Hosted: \(message)"); await noteFailure(message)
                }
                return
            }

            var translation = ""
            reading: for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                switch OpenAITextTranslator.interpret(line) {
                case .text(let chunk):
                    translation += chunk
                    let running = translation
                    await MainActor.run { self.onPartial?(running) }
                case .done: break reading
                case .nothing: continue
                }
            }
            let final = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !final.isEmpty, !Task.isCancelled else { return }
            Log.content(.translation, final)
            await noteSuccess()
            await MainActor.run { self.onFinal?(final) }
        } catch {
            guard !Task.isCancelled else { return }
            Log.error(.openai, "Hosted request failed: \(error.localizedDescription)")
            await noteFailure(error.localizedDescription)
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

    private struct ErrorBody: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }

    private func reportFatal(_ message: String) async {
        Log.error(.openai, "Hosted: \(message)")
        await MainActor.run { self.onFatalError?(message) }
    }
}
