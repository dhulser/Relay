import Foundation
import AVFoundation

/// The two voices Speak ships with. Chosen by ear on 4 Oct 2026 from six
/// OpenAI candidates; see docs/spoken-replies.md §5.
enum SpeakVoice: String, CaseIterable, Identifiable, Codable {
    case nova
    case cedar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nova: return "Nova"
        case .cedar: return "Cedar"
        }
    }

    var detail: String {
        switch self {
        case .nova: return "female"
        case .cedar: return "male"
        }
    }

    /// For the fallback voice, which is picked by gender rather than by name.
    var prefersFemale: Bool { self == .nova }
}

/// Where the voice goes.
enum SpeakOutput: String, CaseIterable, Identifiable, Codable {
    /// For someone in the room.
    case speakers
    /// Through the Relay Voice virtual microphone, picked in the call app.
    case call

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speakers: return "This Mac's speakers"
        case .call: return "The call"
        }
    }

    var detail: String {
        switch self {
        case .speakers:
            return "For someone in the room with you."
        case .call:
            return "Through a microphone called Relay Voice that you pick in Zoom, Meet, Teams or FaceTime. Nobody at this Mac hears it unless you ask."
        }
    }
}

extension Language {
    /// The language for a recogniser's ISO-639-1 code, if Relay offers it.
    init?(isoCode: String) {
        guard let match = Language.allCases.first(where: { $0.isoCode == isoCode.lowercased() }) else { return nil }
        self = match
    }
}

enum SpeechError: LocalizedError {
    case missingAPIKey
    case server(Int, String)
    case noVoice(Language)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenAI key for the natural voices."
        case .server(let status, let message): return "The voice service refused (\(status)): \(message)"
        case .noVoice(let language): return "This Mac has no built-in voice for \(language.displayName)."
        case .cancelled: return "Stopped."
        }
    }
}

/// Turns a sentence into audio, streamed so playback can begin before the
/// sentence is finished. Buffers are in `VoiceOutputService.format`.
protocol SpeechSynthesizing: AnyObject {
    var name: String { get }
    func synthesize(_ text: String, in language: Language) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}
