import Foundation
import AVFoundation

/// The Mac's own voices, rendered to buffers rather than straight to the
/// speakers, so they go through the same output path as the OpenAI voice.
/// Fallback only: the compact voices a fresh Mac ships with are not good
/// enough for a call, and the better ones cannot be downloaded by an app
/// (docs/spoken-replies.md §5).
final class AppleSpeechSynthesizer: NSObject, SpeechSynthesizing {

    let name = "Apple"
    private let preference: SpeakVoice
    private let converter = AudioConverter(target: VoiceOutputService.format)
    /// Kept alive for the length of each render; `write` is asynchronous.
    private var active: AVSpeechSynthesizer?

    init(preference: SpeakVoice) {
        self.preference = preference
    }

    func synthesize(_ text: String, in language: Language) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            guard let voice = Self.voice(for: language, preferringFemale: preference.prefersFemale) else {
                continuation.finish(throwing: SpeechError.noVoice(language))
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            let synthesizer = AVSpeechSynthesizer()
            active = synthesizer
            Log.info(.speak, "Apple voice \(voice.name) (\(voice.language), \(Self.describe(voice.quality)))")
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // The empty buffer marks the end of the utterance.
                    continuation.finish()
                    self?.active = nil
                    return
                }
                if let converted = self?.converter.convert(pcm) {
                    continuation.yield(converted)
                }
            }
            continuation.onTermination = { [weak self] _ in
                synthesizer.stopSpeaking(at: .immediate)
                self?.active = nil
            }
        }
    }

    /// The best installed voice for the language: premium over enhanced over
    /// compact, matching gender where there is a choice.
    static func voice(for language: Language, preferringFemale: Bool) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(language.isoCode.lowercased())
                // Novelty voices (Bells, Cellos…) report no gender and are not voices for a call.
                && $0.gender != .unspecified
        }
        let wanted: AVSpeechSynthesisVoiceGender = preferringFemale ? .female : .male
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            var score = 0
            switch voice.quality {
            case .premium: score += 20
            case .enhanced: score += 10
            default: break
            }
            if voice.gender == wanted { score += 5 }
            return score
        }
        if let best = candidates.max(by: { rank($0) < rank($1) }) { return best }
        return AVSpeechSynthesisVoice(language: language.isoCode)
    }

    private static func describe(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "compact"
        }
    }
}
