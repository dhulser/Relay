import XCTest
import AVFoundation
@testable import Relay

final class SpeakTests: XCTestCase {

    func testSpokenPromptNamesBothLanguagesAndTheVoice() {
        let prompt = TranslationPrompt.spoken(from: .english, to: .spanish)
        XCTAssertTrue(prompt.contains("in English"))
        XCTAssertTrue(prompt.contains("ONLY the Spanish translation"))
        XCTAssertTrue(prompt.contains("read aloud"))
        XCTAssertTrue(prompt.contains("numbers, abbreviations and symbols as words"))
    }

    func testPCM16BytesBecomeFloatSamples() throws {
        var data = Data()
        for sample: Int16 in [0, 16384, -32768, 32767] {
            var little = sample.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        let buffer = try XCTUnwrap(OpenAISpeechSynthesizer.buffer(fromPCM16: data))
        XCTAssertEqual(buffer.frameLength, 4)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], -1)
        XCTAssertEqual(samples[3], 32767 / 32768, accuracy: 0.0001)
    }

    func testEmptyPCMGivesNoBuffer() {
        XCTAssertNil(OpenAISpeechSynthesizer.buffer(fromPCM16: Data()))
        XCTAssertNil(OpenAISpeechSynthesizer.buffer(fromPCM16: Data([0x01])))
    }

    func testVoicesHaveAGenderPreferenceForTheFallback() {
        XCTAssertTrue(SpeakVoice.nova.prefersFemale)
        XCTAssertFalse(SpeakVoice.cedar.prefersFemale)
        XCTAssertEqual(SpeakVoice(rawValue: "nova"), .nova)
    }

    func testLanguageFromISOCode() {
        XCTAssertEqual(Language(isoCode: "es"), .spanish)
        XCTAssertEqual(Language(isoCode: "EN"), .english)
        XCTAssertNil(Language(isoCode: "xx"))
    }

    func testTranscriptMarksYourLines() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 4; parts.hour = 9; parts.minute = 0; parts.second = 7
        let entry = TranscriptEntry(time: Calendar.current.date(from: parts)!, speaker: nil,
                                    original: "Can we start?", translation: "¿Podemos empezar?", you: true)
        XCTAssertEqual(Transcript.text(for: [entry]), "[09:00:07] You: ¿Podemos empezar?\n    Can we start?\n")
    }

    func testEveryMacHasAnEnglishFallbackVoice() {
        XCTAssertNotNil(AppleSpeechSynthesizer.voice(for: .english, preferringFemale: true))
        XCTAssertNotNil(AppleSpeechSynthesizer.voice(for: .english, preferringFemale: false))
    }
}
