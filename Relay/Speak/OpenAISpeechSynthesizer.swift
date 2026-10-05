import Foundation
import AVFoundation

/// OpenAI's speech model, streamed as raw 24 kHz PCM so the first chunk can
/// play while the rest is still being generated. Measured 0.5–0.9 s to first
/// audio from Dylan's Mac (docs/spoken-replies.md §9). The key is never logged.
final class OpenAISpeechSynthesizer: SpeechSynthesizing {

    static let model = "gpt-4o-mini-tts"
    /// One line of direction; the model reads tone from it.
    static let instructions = "You are interpreting for someone on a call. Speak naturally and clearly at a conversational pace, warm and neutral, no theatrical emotion."
    /// 100 ms of 24 kHz Int16 mono per buffer handed to the player.
    static let chunkBytes = 24_000 / 10 * MemoryLayout<Int16>.size

    let name = "OpenAI"
    private let apiKey: String
    private let voice: SpeakVoice
    /// One session for the life of the synthesizer, so the connection stays
    /// warm between sentences; the first request paid ~1 s extra for setup.
    private let session: URLSession

    init(apiKey: String, voice: SpeakVoice) {
        self.apiKey = apiKey
        self.voice = voice
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private struct Body: Encodable {
        let model: String
        let voice: String
        let input: String
        let instructions: String
        let response_format: String
    }

    func synthesize(_ text: String, in language: Language) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(Body(
                        model: Self.model, voice: voice.rawValue, input: text,
                        instructions: Self.instructions, response_format: "pcm"))

                    let started = Date()
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 2000 { break } }
                        let message = Self.errorMessage(in: body) ?? "no detail"
                        Log.error(.speak, "Speech request failed (\(status)): \(message)")
                        throw SpeechError.server(status, message)
                    }

                    var pending = Data()
                    pending.reserveCapacity(Self.chunkBytes * 2)
                    var first = true
                    for try await byte in bytes {
                        pending.append(byte)
                        if pending.count >= Self.chunkBytes {
                            if first {
                                first = false
                                Log.info(.speak, "First audio after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                            }
                            if let buffer = Self.buffer(fromPCM16: pending.prefix(Self.chunkBytes)) {
                                continuation.yield(buffer)
                            }
                            pending.removeFirst(Self.chunkBytes)
                        }
                    }
                    // An odd trailing byte is half a sample; drop it.
                    let whole = pending.count - pending.count % 2
                    if whole > 0, let buffer = Self.buffer(fromPCM16: pending.prefix(whole)) {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: SpeechError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Little-endian Int16 mono at 24 kHz into the player's Float32 format.
    static func buffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: VoiceOutputService.format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0]
        else { return nil }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                out[index] = Float(Int16(littleEndian: samples[index])) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private static func errorMessage(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
