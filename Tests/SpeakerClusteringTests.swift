import XCTest
import AVFoundation
@testable import Relay

/// Does voiceprint clustering actually keep two speakers apart?
///
/// Uses the real embedding model and two genuinely different voices, fed in the
/// interleaved order a conversation would produce — which is the case that
/// matters and the one a naive implementation gets wrong.
final class SpeakerClusteringTests: XCTestCase {

    private func makeService() throws -> SpeakerEmbeddingService {
        let url = ModelStore<SpeakerModel>.directory
            .appendingPathComponent(SpeakerModel.campPlus.fileName)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "Speaker model not downloaded — skipping"
        )
        return try SpeakerEmbeddingService(modelURL: url)
    }

    private func samples(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "wav"),
            "fixture \(name).wav missing from the test bundle"
        )
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw XCTSkip("no converter")
        }
        let ratio = 16_000 / file.processingFormat.sampleRate
        let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096)!

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let channel = try XCTUnwrap(output.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    func testEmbeddingsHaveTheExpectedShape() throws {
        let service = try makeService()
        XCTAssertEqual(service.dimension, 192)

        let embedding = try XCTUnwrap(service.embed(samples("speaker-a1")))
        XCTAssertEqual(embedding.count, 192)
        XCTAssertFalse(embedding.allSatisfy { $0 == 0 }, "embedding must not be all zeros")
    }

    /// The real test: two voices, alternating turns, must land in two groups.
    func testTwoVoicesClusterIntoTwoSpeakersWhenInterleaved() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()

        var assigned: [String: Int] = [:]
        for name in ["speaker-a1", "speaker-b1", "speaker-a2", "speaker-b2"] {
            let embedding = try XCTUnwrap(service.embed(samples(name)), "no embedding for \(name)")
            assigned[name] = clusterer.assign(embedding)
        }

        XCTAssertEqual(assigned["speaker-a1"], assigned["speaker-a2"],
                       "the same voice must reuse its speaker number")
        XCTAssertEqual(assigned["speaker-b1"], assigned["speaker-b2"],
                       "the same voice must reuse its speaker number")
        XCTAssertNotEqual(assigned["speaker-a1"], assigned["speaker-b1"],
                          "two different voices must not collapse into one speaker")
        XCTAssertEqual(clusterer.knownSpeakers, 2,
                       "expected exactly two voices, got \(clusterer.knownSpeakers)")
    }

    /// One voice alone must never be split into several speakers.
    func testOneVoiceStaysOneSpeaker() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()

        for name in ["speaker-a1", "speaker-a2", "speaker-a1"] {
            let embedding = try XCTUnwrap(service.embed(samples(name)))
            _ = clusterer.assign(embedding)
        }
        XCTAssertEqual(clusterer.knownSpeakers, 1)
    }

    /// The case that matters, and the one a threshold tuned on easy audio gets
    /// wrong: two voices of the same gender and language, which score ~0.4
    /// against each other rather than the ~0.1 a female/male pair does.
    func testSimilarVoicesStillSeparate() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()

        var assigned: [String: Int] = [:]
        for name in ["similar-f1a", "similar-f2a", "similar-f1b", "similar-f2b"] {
            let embedding = try XCTUnwrap(service.embed(samples(name)), "no embedding for \(name)")
            assigned[name] = clusterer.assign(embedding)
        }

        XCTAssertEqual(assigned["similar-f1a"], assigned["similar-f1b"],
                       "one voice split across two speakers")
        XCTAssertEqual(assigned["similar-f2a"], assigned["similar-f2b"],
                       "one voice split across two speakers")
        XCTAssertNotEqual(assigned["similar-f1a"], assigned["similar-f2a"],
                          "two similar voices merged into one speaker")
        XCTAssertEqual(clusterer.knownSpeakers, 2)
    }

    /// A short clip may not introduce someone new, but must still be matched to
    /// whoever it actually sounds like — otherwise a second speaker whose
    /// phrases are all short is never discovered.
    func testShortClipsMatchButCannotCreateSpeakers() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()

        let first = clusterer.assign(try XCTUnwrap(service.embed(samples("similar-f1a"))))

        // A different voice arriving on an untrusted clip joins the existing
        // speaker rather than creating one.
        let untrusted = clusterer.assign(
            try XCTUnwrap(service.embed(samples("similar-f2a"))), canCreateSpeaker: false)
        XCTAssertEqual(untrusted, first, "a short clip must not invent a speaker")
        XCTAssertEqual(clusterer.knownSpeakers, 1)

        // The same voice on a trusted clip does create one…
        let second = clusterer.assign(try XCTUnwrap(service.embed(samples("similar-f2b"))))
        XCTAssertNotEqual(second, first)

        // …and now a short clip from that voice matches it correctly.
        let shortMatch = clusterer.assign(
            try XCTUnwrap(service.embed(samples("similar-f2a"))), canCreateSpeaker: false)
        XCTAssertEqual(shortMatch, second, "a short clip must still match the right speaker")
    }

    /// A hard cap is the reliable fix when the user knows the count: no amount
    /// of ambiguous audio may invent a third voice.
    func testSpeakerCapIsNeverExceeded() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()
        clusterer.setMaximum(2)

        // Includes deliberately short clips, which are the ones that used to
        // spawn spurious speakers.
        for name in ["speaker-a1", "speaker-b1", "speaker-a2", "speaker-b2", "speaker-a1"] {
            let embedding = try XCTUnwrap(service.embed(samples(name)))
            _ = clusterer.assign(embedding)
        }
        XCTAssertLessThanOrEqual(clusterer.knownSpeakers, 2)
    }

    /// Whoever spoke last is remembered, so a clip too short to embed can
    /// inherit the current speaker instead of being guessed at.
    func testShortClipsInheritTheCurrentSpeaker() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()

        let first = clusterer.assign(try XCTUnwrap(service.embed(samples("speaker-a1"))))
        XCTAssertEqual(clusterer.inheritLastSpeaker(), first)

        let second = clusterer.assign(try XCTUnwrap(service.embed(samples("speaker-b1"))))
        XCTAssertEqual(clusterer.inheritLastSpeaker(), second)
        XCTAssertNotEqual(first, second)
    }

    func testResetForgetsEveryone() throws {
        let service = try makeService()
        let clusterer = SpeakerClusterer()
        _ = clusterer.assign(try XCTUnwrap(service.embed(samples("speaker-a1"))))
        XCTAssertEqual(clusterer.knownSpeakers, 1)
        clusterer.reset()
        XCTAssertEqual(clusterer.knownSpeakers, 0)
    }
}
