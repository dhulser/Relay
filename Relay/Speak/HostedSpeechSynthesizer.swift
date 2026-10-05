import Foundation
import AVFoundation

/// Speak through Relay Hosted or a company account: the sentence goes to the
/// Relay API, which holds the key and streams OpenAI's PCM back unchanged,
/// metered by the second of speech. Same bytes as the direct route, so the
/// parsing is shared.
final class HostedSpeechSynthesizer: SpeechSynthesizing {

    let name: String
    private let token: String
    private let voice: SpeakVoice
    private let session: URLSession

    init(token: String, voice: SpeakVoice, accountName: String) {
        self.token = token
        self.voice = voice
        self.name = accountName
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private struct Body: Encodable { let text: String; let voice: String }

    func synthesize(_ text: String, in language: Language) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        var request = URLRequest(url: HostedAccount.speakEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Body(text: text, voice: voice.rawValue))
        return OpenAISpeechSynthesizer.stream(request, on: session, from: name)
    }
}
