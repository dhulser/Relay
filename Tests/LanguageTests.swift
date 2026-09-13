import XCTest
@testable import Relay

final class LanguageTests: XCTestCase {

    func testEveryLanguageIsOneWhisperKnows() {
        for language in Language.allCases {
            XCTAssertGreaterThanOrEqual(whisper_lang_id(language.isoCode), 0,
                                        "\(language.displayName) (\(language.isoCode)) is not a Whisper language")
        }
    }

    func testCodesAndNamesAreUnique() {
        let codes = Language.allCases.map(\.isoCode)
        XCTAssertEqual(Set(codes).count, codes.count)
        let names = Language.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testListIsAlphabetical() {
        let names = Language.allCases.map(\.displayName)
        XCTAssertEqual(names, names.sorted())
    }

    func testStoredValuesFromEarlierVersionsStillResolve() {
        // The nine original languages are what people already have in defaults.
        for raw in ["spanish", "english", "french", "german", "italian", "portuguese", "japanese", "korean", "chinese"] {
            XCTAssertNotNil(Language(rawValue: raw), raw)
        }
    }

    func testWordCountHandlesSpacedAndUnspacedScripts() {
        XCTAssertEqual(TranslationStats.wordCount(in: "I'll send the numbers tomorrow"), 5)
        XCTAssertEqual(TranslationStats.wordCount(in: "明日数字を送ります"), 9)
        XCTAssertEqual(TranslationStats.wordCount(in: "我明天发给你。"), 6, "punctuation is not a word")
        XCTAssertEqual(TranslationStats.wordCount(in: "내일 숫자를 보내겠습니다"), 3, "Korean uses spaces")
        XCTAssertEqual(TranslationStats.wordCount(in: "  \n "), 0)
    }
}
