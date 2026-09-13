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

    // MARK: - Breakdown, records and discoveries

    func testWordsAreAttributedToTheirLanguage() {
        stats.record(line: "one two three", language: "es")
        stats.record(line: "four five", language: "es")
        stats.record(line: "six", language: "fr")

        XCTAssertEqual(stats.wordsByLanguage["es"], 5)
        XCTAssertEqual(stats.wordsByLanguage["fr"], 1)
        XCTAssertEqual(stats.words, 6, "the overall total still counts everything")
    }

    /// The breakdown leads with whatever you listen to most.
    func testBreakdownIsOrderedByVolume() {
        stats.record(line: "one", language: "fr")
        stats.record(line: "one two three four", language: "es")
        stats.record(line: "one two", language: "ja")

        let order = stats.breakdown.map(\.language)
        XCTAssertEqual(order, ["Spanish", "Japanese", "French"])
    }

    /// Realtime reports no language, so those words count towards the total
    /// without inventing a language for the breakdown.
    func testWordsWithoutALanguageStillCount() {
        stats.record(line: "one two three")
        XCTAssertEqual(stats.words, 3)
        XCTAssertTrue(stats.breakdown.isEmpty)
    }

    func testBestDayTracksTheRunningTotal() {
        XCTAssertNil(stats.bestDayText, "no record before anything is translated")

        stats.record(line: "one two three")
        XCTAssertEqual(stats.bestDayWords, 3)

        stats.record(line: "four five")
        XCTAssertEqual(stats.bestDayWords, 5, "the record grows as the day does")
        XCTAssertNotNil(stats.bestDayText)
    }

    /// Hearing something new is worth a remark, but only the first time.
    func testFirstTimeHearingALanguageIsNoted() {
        XCTAssertNil(stats.justDiscovered)

        stats.record(language: "ja")
        XCTAssertEqual(stats.justDiscovered, "Japanese")

        stats.acknowledgeDiscovery()
        XCTAssertNil(stats.justDiscovered)

        stats.record(language: "ja")
        XCTAssertNil(stats.justDiscovered, "already heard, so not a discovery")
    }

    func testUnknownLanguageIsNotADiscovery() {
        stats.record(language: "xx")
        XCTAssertNil(stats.justDiscovered)
    }

    func testResetClearsEverything() {
        stats.record(line: "some words here", language: "es")
        stats.record(language: "es")
        stats.reset()

        XCTAssertEqual(stats.words, 0)
        XCTAssertTrue(stats.languages.isEmpty)
        XCTAssertTrue(stats.breakdown.isEmpty)
        XCTAssertEqual(stats.bestDayWords, 0)
        XCTAssertNil(stats.bestDayText)
        XCTAssertFalse(stats.hasAnything)
    }
}
