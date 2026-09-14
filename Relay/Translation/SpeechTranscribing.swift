import Foundation
import AVFoundation

/// One recognised utterance.
struct TranscriptionResult {
    let text: String
    /// ISO-639-1 code the recogniser identified, when it can identify one.
    /// Apple's recogniser always returns the locale it was configured with;
    /// Whisper returns what it actually heard.
    let languageCode: String?
    /// 1-based speaker number from voiceprint clustering, when enabled.
    let speaker: Int?

    init(text: String, languageCode: String?, speaker: Int? = nil) {
        self.text = text
        self.languageCode = languageCode
        self.speaker = speaker
    }
}

/// Turns captured audio into finished utterances of text.
///
/// Only settled utterances are published. Translating every revision of an
/// in-progress phrase would multiply API calls for text that's about to change.
protocol SpeechTranscribing: AnyObject {
    var onFinalText: ((TranscriptionResult) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    /// `language` is nil when the user asked for auto-detect. Implementations
    /// that can't detect should throw rather than silently pick one.
    func start(language: Language?) async throws
    func receive(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

/// Translates finished utterances into the target language.
protocol TextTranslating: AnyObject {
    /// The translation so far for the utterance in flight.
    var onPartial: ((String) -> Void)? { get set }
    /// The finished translation of an utterance.
    var onFinal: ((String) -> Void)? { get set }
    /// Unrecoverable — bad key, refused model.
    var onFatalError: ((String) -> Void)? { get set }
    /// Repeated recoverable failures (no credits, rate limits, network). The
    /// message describes the last one; nil means it started working again.
    var onTrouble: ((String?) -> Void)? { get set }

    func translate(_ utterance: String)
    func cancel()
}
