import XCTest
@testable import Relay

final class TranscriptTests: XCTestCase {

    private func entry(_ translation: String, original: String? = nil, speaker: Int? = nil, second: Int = 0) -> TranscriptEntry {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 12; parts.hour = 10; parts.minute = 32; parts.second = second
        return TranscriptEntry(time: Calendar.current.date(from: parts)!, speaker: speaker,
                               original: original, translation: translation)
    }

    func testLinesCarryTimeSpeakerAndIndentedOriginal() {
        let text = Transcript.text(for: [
            entry("That works for me.", original: "Me parece bien.", speaker: 1, second: 5),
            entry("Could we push it to Thursday?", second: 9),
        ])
        XCTAssertEqual(text, """
        [10:32:05] Speaker 1: That works for me.
            Me parece bien.
        [10:32:09] Could we push it to Thursday?

        """)
    }

    func testOriginalIdenticalToTranslationIsNotRepeated() {
        let text = Transcript.text(for: [entry("Okay.", original: "Okay.")])
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2)
    }

    func testSuggestedNameUsesTheFirstLineTime() {
        let name = Transcript.suggestedFileName(for: [entry("x", second: 0)])
        XCTAssertEqual(name, "Relay transcript 2026-09-12 10.32.txt")
    }
}
