import Foundation
import AVFoundation

/// How audio becomes translated subtitles.
enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    /// Recognise on this Mac, translate with Claude.
    case claude
    /// Recognise on this Mac, translate with an OpenAI text model.
    case openai
    /// Stream audio straight to OpenAI's speech-to-translation model.
    case openaiRealtime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .openaiRealtime: return "OpenAI Realtime"
        }
    }

    /// Compact name for the compare overlay, where space is tight.
    var shortLabel: String {
        switch self {
        case .claude: return "Local · Claude"
        case .openai: return "Local · OpenAI"
        case .openaiRealtime: return "Realtime"
        }
    }

    /// Whether speech recognition happens locally. The Realtime model takes
    /// audio directly, so it has no local half.
    var usesLocalSpeech: Bool { self != .openaiRealtime }

    /// Keychain account. Both OpenAI providers share one key.
    var keychainAccount: String {
        switch self {
        case .claude: return "anthropic-api-key"
        case .openai, .openaiRealtime: return "openai-api-key"
        }
    }

    /// The service the key belongs to — two providers can share one.
    var credentialName: String {
        switch self {
        case .claude: return "Anthropic"
        case .openai, .openaiRealtime: return "OpenAI"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .claude: return "sk-ant-…"
        case .openai, .openaiRealtime: return "sk-…"
        }
    }

    var pipelineDescription: String {
        switch self {
        case .claude:
            return "Speech is recognised on this Mac, then Claude translates the text."
        case .openai:
            return "Speech is recognised on this Mac, then an OpenAI text model translates it."
        case .openaiRealtime:
            return "Audio streams to OpenAI's translation model, which identifies the language itself."
        }
    }

    /// Rough running cost for an hour of typical speech. Recalculated after the
    /// system prompt was cut from ~280 tokens to ~124, which roughly halved the
    /// input billed per utterance.
    var costPerHour: String {
        switch self {
        case .claude: return "about $0.19 an hour"
        case .openai: return "about $0.04 an hour"
        case .openaiRealtime: return "$2.04 an hour"
        }
    }

    /// Where the audio goes — the thing most worth knowing at a glance.
    var privacyNote: String {
        switch self {
        case .claude, .openai: return "audio stays on your Mac"
        case .openaiRealtime: return "audio is sent to OpenAI"
        }
    }

    /// The one trade worth surfacing next to the choice.
    var characteristic: String {
        switch self {
        case .claude, .openai: return "Lines appear when a phrase finishes."
        case .openaiRealtime: return "Lines appear while the speaker is still talking."
        }
    }

}

/// Which recogniser handles the local half of the pipeline.
enum SpeechEngine: String, CaseIterable, Identifiable, Codable {
    case whisper
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .apple: return "Apple"
        }
    }

    var subtitle: String {
        switch self {
        case .whisper: return "Detects the language automatically, 100 languages"
        case .apple: return "Lower latency, but one language at a time"
        }
    }

    /// Whisper identifies the language of every utterance; Apple's recogniser
    /// is loaded for one specific language and can't.
    var detectsLanguage: Bool { self == .whisper }
}

/// OpenAI text models for the translation half.
enum OpenAITextModel: String, CaseIterable, Identifiable, Codable {
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .luna: return "Luna"
        case .terra: return "Terra"
        case .sol: return "Sol"
        }
    }

    var subtitle: String {
        switch self {
        case .luna: return "$0.20/$1.20 — fastest, cheapest"
        case .terra: return "$2/$12 — balanced"
        case .sol: return "$5/$30 — most capable"
        }
    }
}

/// Claude models for the translation half.
enum ClaudeModel: String, CaseIterable, Identifiable, Codable {
    case haiku45 = "claude-haiku-4-5"
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku45: return "Haiku 4.5"
        case .sonnet5: return "Sonnet 5"
        case .opus5: return "Opus 5"
        }
    }

    var subtitle: String {
        switch self {
        case .haiku45: return "$1/$5 — fastest, cheapest"
        case .sonnet5: return "$3/$15 — better idiom and tone"
        case .opus5: return "$5/$25 — best quality, slowest"
        }
    }

    /// Sonnet 5 and Opus 5 think by default. A one-sentence translation gains
    /// nothing from it and pays the latency, so it's turned off explicitly.
    var thinkingOnByDefault: Bool { self != .haiku45 }
}

/// What the user picked for the source language.
enum SourceLanguageSetting: Hashable {
    case auto
    case explicit(Language)

    var language: Language? {
        if case .explicit(let language) = self { return language }
        return nil
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .explicit(let language): return language.displayName
        }
    }

    var storageValue: String {
        switch self {
        case .auto: return "auto"
        case .explicit(let language): return language.rawValue
        }
    }

    init(storageValue: String) {
        if storageValue == "auto" {
            self = .auto
        } else if let language = Language(rawValue: storageValue) {
            self = .explicit(language)
        } else {
            self = .auto
        }
    }

}

enum EngineState: Equatable {
    case idle
    case connecting
    case ready
    case reconnecting
}

enum EngineError: LocalizedError {
    case missingAPIKey(TranslationProvider)
    case unsupportedLanguage(String)
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            // Deliberately not naming the provider: Settings already shows which
            // one is selected, and naming it here reads as though the wrong key
            // was entered rather than none.
            return "Add your API key in Settings to start translating."
        case .unsupportedLanguage(let detail):
            return detail
        case .setupFailed(let detail):
            return detail
        }
    }
}

/// Everything a translation backend has to do.
///
/// `receive(_:)` is called on the audio capture queue; every callback is
/// delivered on the main queue.
protocol TranslationEngine: AnyObject {
    var onStateChange: ((EngineState) -> Void)? { get set }
    /// Text plus the speaker it belongs to, when the pipeline can tell.
    var onPartialTranslation: ((String, Int?) -> Void)? { get set }
    var onFinalTranslation: ((String, Int?) -> Void)? { get set }
    var onFatalError: ((String) -> Void)? { get set }

    func start(source: SourceLanguageSetting, target: Language) throws
    func receive(_ buffer: AVAudioPCMBuffer)
    func stop()
}
