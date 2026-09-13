import Foundation
import SherpaOnnxC

/// Facts about the linked sherpa-onnx build. Reading the version at launch
/// proves the framework is genuinely wired up at runtime, not only at compile
/// time — the same check that caught whisper's linkage early.
enum SpeakerRuntime {
    static var version: String {
        guard let raw = SherpaOnnxGetVersionStr() else { return "unknown" }
        return String(cString: raw)
    }
}

/// The speaker-embedding model. One option for now: CAM++ trained on Chinese
/// and English, which is the best-tested multilingual choice. Voice embeddings
/// encode timbre rather than words, so the training languages matter far less
/// than they would for recognition.
enum SpeakerModel: String, CaseIterable, Identifiable, Codable, DownloadableModel {
    case campPlus

    var id: String { rawValue }
    var displayName: String { "CAM++" }
    var fileName: String { "speaker-campplus.onnx" }
    var approximateBytes: Int64 { 27_000_000 }

    var downloadURL: URL {
        // Note the upstream typo in the tag name: "recongition".
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
            + "speaker-recongition-models/"
            + "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!
    }
}
