import XCTest
@testable import Relay

@MainActor
final class TranslationStatsTests: XCTestCase {

    private var stats: TranslationStats!

    override func setUp() {
        super.setUp()
        stats = TranslationStats()
        stats.reset()
    }

    override func tearDown() {
        stats.reset()
        super.tearDown()
    }

    func testNothingToShowBeforeAnythingHappens() {
        XCTAssertFalse(stats.hasAnything)
        XCTAssertEqual(stats.words, 0)
        XCTAssertNil(stats.languagesText)
    }

    func testCountsWordsAcrossLines() {
        stats.record(line: "I'll send the numbers over tomorrow morning.")   // 7
        stats.record(line: "Before anyone gets into the meeting.")            // 6
        XCTAssertEqual(stats.words, 13)
        XCTAssertTrue(stats.hasAnything)
    }

    /// Line breaks and runs of spaces must not inflate the count.
    func testAwkwardWhitespaceDoesNotInflateTheCount() {
        stats.record(line: "  two   words\n")
        XCTAssertEqual(stats.words, 2)
        stats.record(line: "   ")
        XCTAssertEqual(stats.words, 2, "whitespace alone is not a line")
    }

    func testThousandsAreGrouped() {
        for _ in 0..<200 { stats.record(line: "one two three four five six seven") }
        XCTAssertEqual(stats.words, 1400)
        XCTAssertTrue(stats.wordsText.contains("1") && stats.wordsText.count > 4,
                      "expected a grouped figure, got \(stats.wordsText)")
    }

    /// Hearing the same language repeatedly is still one language.
    func testLanguagesAreNamedAndDeduplicated() {
        stats.record(language: "es")
        stats.record(language: "es")
        stats.record(language: "fr")
        XCTAssertEqual(stats.languages.count, 2)
        XCTAssertEqual(stats.languagesText, "French and Spanish")
    }

    func testThreeLanguagesReadAsAList() {
        ["es", "fr", "ja"].forEach { stats.record(language: $0) }
        XCTAssertEqual(stats.languagesText, "French, Japanese and Spanish")
    }

    /// Past three, naming them all would overflow the popover.
    func testManyLanguagesSummarise() {
        ["es", "fr", "ja", "de", "it"].forEach { stats.record(language: $0) }
        XCTAssertEqual(stats.languagesText, "French, German and 3 more")
    }

    /// Realtime reports no language, which must not count as one.
    func testUnknownLanguageIsIgnored() {
        stats.record(language: nil)
        stats.record(language: "")
        XCTAssertTrue(stats.languages.isEmpty)
        XCTAssertNil(stats.languagesText)
    }

    func testListeningTimeReadsNaturally() {
        XCTAssertEqual(stats.listeningText, "under a minute")
        stats.beginSession()
        stats.endSession()
        XCTAssertEqual(stats.listeningText, "under a minute", "a blink is not a minute")
    }

    func testResetClearsEverything() {
        stats.record(line: "some words here")
        stats.record(language: "es")
        stats.reset()

        XCTAssertEqual(stats.words, 0)
        XCTAssertTrue(stats.languages.isEmpty)
        XCTAssertFalse(stats.hasAnything)
    }
}
