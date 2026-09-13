import Foundation

/// Silero VAD in whisper.cpp's GGML format. Under a megabyte, and when enabled
/// it strips music, noise and silence out of each phrase before Whisper sees
/// it, which is what stops Whisper inventing words over a soundtrack.
enum VoiceActivityModel: String, CaseIterable, Identifiable, Codable, DownloadableModel {
    case silero

    var id: String { rawValue }
    var displayName: String { "Silero VAD" }
    var fileName: String { "ggml-silero-v5.1.2.bin" }
    var approximateBytes: Int64 { 900_000 }

    /// Published by the whisper.cpp maintainers alongside the speech models.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    }
}

extension ModelStore where Model == VoiceActivityModel {
    static let voiceActivity = ModelStore<VoiceActivityModel>(category: .whisper)
}
