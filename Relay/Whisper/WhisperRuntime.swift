import Foundation

/// Thin facts about the linked whisper.cpp build, and the models we offer.
enum WhisperRuntime {
    static var version: String { String(cString: whisper_version()) }

    /// Number of languages the multilingual models can identify.
    static var languageCount: Int { Int(whisper_lang_max_id()) + 1 }

    /// ISO-639-1 code for a whisper language id, e.g. 2 → "de".
    static func languageCode(for id: Int32) -> String? {
        guard let cString = whisper_lang_str(id) else { return nil }
        return String(cString: cString)
    }
}

/// The multilingual GGML models worth offering. English-only variants are
/// deliberately excluded — the whole point here is language auto-detection.
enum WhisperModel: String, CaseIterable, Identifiable, Codable, DownloadableModel {
    case base
    case small
    case medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        }
    }

    var subtitle: String {
        switch self {
        case .base: return "142 MB — fastest, good for clear speech"
        case .small: return "466 MB — recommended balance"
        case .medium: return "1.5 GB — most accurate, slowest"
        }
    }

    var fileName: String { "ggml-\(rawValue).bin" }

    /// Official GGML weights published by the whisper.cpp authors.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var approximateBytes: Int64 {
        switch self {
        case .base: return 148_000_000
        case .small: return 488_000_000
        case .medium: return 1_530_000_000
        }
    }
}
