import XCTest
@testable import Relay

/// The comparison pair is persisted as two strings, so the round trip has to
/// survive a relaunch and tolerate whatever an older build left behind.
final class ComparisonEngineTests: XCTestCase {

    func testEveryEngineRoundTripsThroughStorage() {
        for engine in ComparisonEngine.all {
            let restored = ComparisonEngine(storageValue: engine.storageValue)
            XCTAssertEqual(restored, engine, "\(engine.storageValue) did not survive the round trip")
        }
    }

    func testOffersEveryModelOfEveryProviderPlusInstant() {
        XCTAssertEqual(ComparisonEngine.all.count,
                       ClaudeModel.allCases.count + OpenAITextModel.allCases.count + 1)
        XCTAssertTrue(ComparisonEngine.all.contains(.instant))
    }

    func testGarbageAndRetiredModelsAreRefusedRatherThanGuessed() {
        XCTAssertNil(ComparisonEngine(storageValue: ""))
        XCTAssertNil(ComparisonEngine(storageValue: "claude"))
        XCTAssertNil(ComparisonEngine(storageValue: "claude:claude-haiku-1"))
        XCTAssertNil(ComparisonEngine(storageValue: "gemini:pro"))
        XCTAssertNil(ComparisonEngine(storageValue: "openai:gpt-1"))
    }

    func testTwoModelsFromOneProviderAreDistinct() {
        let haiku = ComparisonEngine.claude(.haiku45)
        let sonnet = ComparisonEngine.claude(.sonnet5)
        XCTAssertNotEqual(haiku, sonnet)
        XCTAssertNotEqual(haiku.shortLabel, sonnet.shortLabel)
        XCTAssertNotEqual(haiku.storageValue, sonnet.storageValue)
        XCTAssertEqual(haiku.provider, sonnet.provider, "both are still Claude")
    }

    func testLabelsNameTheProviderAndTheModel() {
        XCTAssertEqual(ComparisonEngine.claude(.haiku45).shortLabel, "Claude · Haiku 4.5")
        XCTAssertEqual(ComparisonEngine.openai(.luna).shortLabel, "OpenAI · Luna")
        XCTAssertEqual(ComparisonEngine.instant.shortLabel, "Instant")
    }

    func testProviderAndInstantAgree() {
        XCTAssertEqual(ComparisonEngine.instant.provider, .openaiRealtime)
        XCTAssertTrue(ComparisonEngine.instant.isInstant)
        for engine in ComparisonEngine.all where !engine.isInstant {
            XCTAssertTrue(engine.provider.usesLocalSpeech, "\(engine.shortLabel) should be a local engine")
        }
    }

    func testEveryEngineQuotesAnHourlyCost() {
        for engine in ComparisonEngine.all {
            XCTAssertTrue(engine.costPerHour.contains("hour"), engine.shortLabel)
        }
    }
}
