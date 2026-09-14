import XCTest
import AVFoundation
@testable import Relay

/// End-to-end check of the local speech path: audio arrives shaped exactly the
/// way the system-audio tap delivers it, and Spanish text with a detected language
/// comes out the other side.
///
/// This covers the parts of the pipeline that need no API key — capture format
/// conversion, phrase segmentation, whisper.cpp inference, and per-utterance
/// language identification.
final class WhisperTranscriptionTests: XCTestCase {

    /// What the system-audio tap hands us on this Mac.
    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
    )!

    func testTranscribesSpanishAndDetectsTheLanguage() async throws {
        try await assertTranscribesSpanish(gain: 1, hiss: 0)
    }

    /// A quiet speaker on a call, with the faint steady hiss a call carries.
    /// System audio uses the fixed threshold, so this must still be heard.
    func testQuietSpeechOverSteadyHissStillTranscribes() async throws {
        try await assertTranscribesSpanish(gain: 0.08, hiss: 0.003)
    }

    private func assertTranscribesSpanish(gain: Float, hiss: Float) async throws {
        let model = WhisperModel.base
        let modelURL = ModelStore<WhisperModel>.directory.appendingPathComponent(model.fileName)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path),
            "Whisper \(model.displayName) model not downloaded — skipping"
        )

        let fixture = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "spanish-sample", withExtension: "aiff"),
            "fixture missing from the test bundle"
        )

        let service = WhisperTranscriptionService(model: model, modelURL: modelURL)
        let received = expectation(description: "utterance transcribed")
        let result = UncheckedBox<TranscriptionResult?>(nil)

        service.onFinalText = { transcription in
            guard result.value == nil else { return }
            result.value = transcription
            received.fulfill()
        }
        service.onError = { XCTFail("recognition failed: \($0.localizedDescription)") }

        try await service.start(language: nil)   // nil = auto-detect

        // A little hiss first, so the noise floor has something to settle on.
        for buffer in Self.silenceBuffers(seconds: 1.0) {
            service.receive(Self.shaped(buffer, gain: 1, hiss: hiss))
        }
        for buffer in try Self.captureBuffers(from: fixture) {
            service.receive(Self.shaped(buffer, gain: gain, hiss: hiss))
        }
        // Trailing silence closes the phrase, the way a real pause would.
        for buffer in Self.silenceBuffers(seconds: 1.2) {
            service.receive(Self.shaped(buffer, gain: 1, hiss: hiss))
        }

        await fulfillment(of: [received], timeout: 30)
        await service.stop()

        let transcription = try XCTUnwrap(result.value)
        XCTAssertEqual(transcription.languageCode, "es",
                       "auto-detect should identify Spanish, got \(transcription.languageCode ?? "nil")")

        // Don't assert an exact transcript — recognisers vary on articles and
        // punctuation. Assert the content words that carry the meaning.
        let text = transcription.text.lowercased()
        for expected in ["informe", "mañana", "reunión"] {
            XCTAssertTrue(text.contains(expected),
                          "expected \"\(expected)\" in transcript: \(transcription.text)")
        }
    }

    // MARK: - Helpers

    /// Scales the audio and adds uniform noise of the given RMS, in place.
    private static func shaped(_ buffer: AVAudioPCMBuffer, gain: Float, hiss: Float) -> AVAudioPCMBuffer {
        guard gain != 1 || hiss > 0, let channels = buffer.floatChannelData else { return buffer }
        let amplitude = hiss * 1.732   // uniform noise: RMS = amplitude / sqrt(3)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] = channels[channel][frame] * gain + Float.random(in: -amplitude...amplitude)
            }
        }
        return buffer
    }

    /// Reads the fixture and re-chunks it into 20 ms 48 kHz stereo buffers,
    /// matching what the capture service emits.
    private static func captureBuffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)

        let converter = AVAudioConverter(from: file.processingFormat, to: captureFormat)!
        let ratio = captureFormat.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096
        let resampled = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity)!

        var supplied = false
        var error: NSError?
        converter.convert(to: resampled, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }

        return slice(resampled, chunkFrames: 960)   // 20 ms at 48 kHz
    }

    private static func silenceBuffers(seconds: Double) -> [AVAudioPCMBuffer] {
        let total = Int(captureFormat.sampleRate * seconds)
        return (0..<(total / 960)).map { _ in
            let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 960)!
            buffer.frameLength = 960
            for channel in 0..<Int(captureFormat.channelCount) {
                memset(buffer.floatChannelData![channel], 0, 960 * MemoryLayout<Float>.size)
            }
            return buffer
        }
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, chunkFrames: Int) -> [AVAudioPCMBuffer] {
        var chunks: [AVAudioPCMBuffer] = []
        var offset = 0
        let total = Int(buffer.frameLength)

        while offset < total {
            let frames = min(chunkFrames, total - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: AVAudioFrameCount(frames))!
            chunk.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(chunk.floatChannelData![channel],
                       buffer.floatChannelData![channel] + offset,
                       frames * MemoryLayout<Float>.size)
            }
            chunks.append(chunk)
            offset += frames
        }
        return chunks
    }
}

/// Lets a callback on the inference queue hand a value back to the test.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
