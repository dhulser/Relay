import Foundation

/// Wire types for the Realtime translations endpoint.
///
/// Outbound events are strongly typed because we have to get them exactly right.
/// Inbound events are deliberately loose: the server sends many event types we
/// don't care about, and one tolerant struct beats two dozen precise ones we'd
/// have to keep in sync.
enum RealtimeAPI {
    static let model = "gpt-realtime-translate"
    static let transcriptionModel = "gpt-realtime-whisper"

    static var url: URL {
        URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(model)")!
    }
}

// MARK: - Client events

struct SessionUpdateEvent: Encodable {
    struct Session: Encodable {
        struct Audio: Encodable {
            struct Input: Encodable {
                struct Transcription: Encodable {
                    let model: String
                    /// ISO-639-1 hint for the spoken language. Omitted entirely
                    /// when the user picked Auto-detect — the translation model
                    /// identifies the language itself across 70+ inputs, and a
                    /// wrong hint would only fight it.
                    let language: String?
                }
                let transcription: Transcription
            }
            struct Output: Encodable {
                /// ISO-639-1 code of the language to translate into.
                let language: String
            }
            let input: Input
            let output: Output
        }
        let audio: Audio
    }

    let type = "session.update"
    let session: Session

    init(sourceLanguage: SourceLanguageSetting, targetLanguage: Language) {
        session = Session(audio: .init(
            input: .init(transcription: .init(
                model: RealtimeAPI.transcriptionModel,
                language: sourceLanguage.language?.isoCode
            )),
            output: .init(language: targetLanguage.isoCode)
        ))
    }
}

struct AudioAppendEvent: Encodable {
    let type = "session.input_audio_buffer.append"
    /// Base64 of 24 kHz mono PCM16 little-endian. Never logged.
    let audio: String
}

// MARK: - Server events

/// One shape for every inbound event. Fields are optional because which ones
/// are present depends on `type`.
struct RealtimeServerEvent: Decodable {
    struct APIError: Decodable {
        let type: String?
        let code: String?
        let message: String?
    }

    let type: String
    let delta: String?
    let transcript: String?
    let text: String?
    let error: APIError?

    /// Text carried by this event, whichever field it arrived in.
    var payloadText: String? {
        delta ?? transcript ?? text
    }
}

/// What an inbound event means to us, independent of the exact string OpenAI used.
///
/// Matching on suffixes rather than whole strings is deliberate: the translations
/// endpoint prefixes its events with `session.` while the general realtime
/// endpoint does not, and this keeps us working either way.
enum RealtimeEventKind {
    case sessionReady
    case translatedDelta(String)
    case translatedCompleted(String)
    case sourceTranscript(String)
    case speechStarted
    case speechStopped
    case audioChunk          // translated speech — ignored, we only want text
    case error(String)
    case other(String)

    init(from event: RealtimeServerEvent) {
        let type = event.type
        let text = event.payloadText ?? ""

        if type == "error" || type.hasSuffix(".error") {
            let message = event.error?.message ?? "Unknown Realtime API error"
            self = .error(message)
        } else if type.hasSuffix("session.created") || type.hasSuffix("session.updated") {
            self = .sessionReady
        } else if type.hasSuffix("output_transcript.delta") || type.hasSuffix("output_text.delta") {
            self = .translatedDelta(text)
        } else if type.hasSuffix("output_transcript.done") || type.hasSuffix("output_transcript.completed")
                    || type.hasSuffix("output_text.done") {
            self = .translatedCompleted(text)
        } else if type.hasSuffix("input_transcript.delta") || type.hasSuffix("input_transcript.done") {
            self = .sourceTranscript(text)
        } else if type.hasSuffix("speech_started") {
            self = .speechStarted
        } else if type.hasSuffix("speech_stopped") {
            self = .speechStopped
        } else if type.hasSuffix("output_audio.delta") {
            self = .audioChunk
        } else {
            self = .other(type)
        }
    }
}
