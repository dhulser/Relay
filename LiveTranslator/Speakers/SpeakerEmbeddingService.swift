import Foundation
import SherpaOnnxC

/// Turns a chunk of speech into a voiceprint — a fixed-length vector that
/// encodes *how* a voice sounds rather than what was said.
///
/// Because it models timbre, it works regardless of language, which is why this
/// can label speakers on audio Whisper is still auto-detecting the language of.
final class SpeakerEmbeddingService {

    private var extractor: OpaquePointer?
    private(set) var dimension = 0

    init(modelURL: URL, threads: Int32 = 2) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EngineError.setupFailed(
                "The speaker model isn't downloaded yet. Open Settings to get it."
            )
        }

        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.num_threads = threads
        config.debug = 0

        let created: OpaquePointer? = modelURL.path.withCString { model in
            "cpu".withCString { provider in
                config.model = model
                config.provider = provider
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }

        guard let created else {
            throw EngineError.setupFailed("Could not load the speaker model.")
        }
        extractor = created
        dimension = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(created))
        Log.info(.speakers, "Loaded speaker model (\(dimension)-dim)")
    }

    deinit {
        if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
    }

    /// 16 kHz mono float samples in, voiceprint out. Nil when the clip is too
    /// short for the model to say anything useful.
    func embed(_ samples: [Float], sampleRate: Int32 = 16_000) -> [Float]? {
        guard let extractor,
              let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor)
        else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)

        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1,
              let raw = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream)
        else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(raw) }

        return Array(UnsafeBufferPointer(start: raw, count: dimension))
    }
}
