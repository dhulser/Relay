import XCTest
@testable import Relay

/// Round-trips against the real Keychain under a test-only service name, so
/// the user's actual keys are never touched.
final class KeychainServiceTests: XCTestCase {
    private let service = "co.kevel.Relay.tests"

    override func tearDown() {
        for provider in TranslationProvider.allCases {
            KeychainService.deleteAPIKey(for: provider, service: service)
        }
    }

    func testSaveLoadReplaceDelete() {
        XCTAssertNil(KeychainService.loadAPIKey(for: .claude, service: service))

        XCTAssertTrue(KeychainService.saveAPIKey("sk-ant-first", for: .claude, service: service))
        XCTAssertEqual(KeychainService.loadAPIKey(for: .claude, service: service), "sk-ant-first")
        XCTAssertTrue(KeychainService.hasAPIKey(for: .claude, service: service))

        XCTAssertTrue(KeychainService.saveAPIKey("sk-ant-second", for: .claude, service: service))
        XCTAssertEqual(KeychainService.loadAPIKey(for: .claude, service: service), "sk-ant-second")

        XCTAssertTrue(KeychainService.deleteAPIKey(for: .claude, service: service))
        XCTAssertNil(KeychainService.loadAPIKey(for: .claude, service: service))
        XCTAssertFalse(KeychainService.hasAPIKey(for: .claude, service: service))
    }

    func testWhitespaceIsTrimmedAndBlankMeansDelete() {
        KeychainService.saveAPIKey("  sk-padded \n", for: .openai, service: service)
        XCTAssertEqual(KeychainService.loadAPIKey(for: .openai, service: service), "sk-padded")

        KeychainService.saveAPIKey("   ", for: .openai, service: service)
        XCTAssertNil(KeychainService.loadAPIKey(for: .openai, service: service))
    }

    func testBothOpenAIProvidersShareOneKey() {
        KeychainService.saveAPIKey("sk-shared", for: .openai, service: service)
        XCTAssertEqual(KeychainService.loadAPIKey(for: .openaiRealtime, service: service), "sk-shared")
    }

    func testDeletingAMissingKeyIsNotAnError() {
        XCTAssertTrue(KeychainService.deleteAPIKey(for: .claude, service: service))
    }
}
