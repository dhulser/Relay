import XCTest
@testable import Relay

/// The bits of the network layer that can be checked without a network: how a
/// line of each provider's stream is read, and how Realtime events are sorted.
final class WireFormatTests: XCTestCase {

    // MARK: - Anthropic SSE

    func testClaudeTextDeltaIsExtracted() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola"}}"#
        XCTAssertEqual(ClaudeTranslator.interpret(line), .text("Hola"))
    }

    func testClaudeIgnoresEventNamesAndBlankLines() {
        XCTAssertEqual(ClaudeTranslator.interpret("event: content_block_delta"), .nothing)
        XCTAssertEqual(ClaudeTranslator.interpret(""), .nothing)
        XCTAssertEqual(ClaudeTranslator.interpret(#"data: {"type":"ping"}"#), .nothing)
    }

    func testClaudeEmptyDeltaIsNothing() {
        let line = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":""}}"#
        XCTAssertEqual(ClaudeTranslator.interpret(line), .nothing)
    }

    func testClaudeRefusalIsReported() {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#
        XCTAssertEqual(ClaudeTranslator.interpret(line), .refusal)
        let normal = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#
        XCTAssertEqual(ClaudeTranslator.interpret(normal), .nothing)
    }

    func testClaudeStreamErrorCarriesTheMessage() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(ClaudeTranslator.interpret(line), .error("Overloaded"))
    }

    func testClaudeFatalMessagesAreRecognised() {
        XCTAssertTrue(ClaudeTranslator.isFatal("invalid x-api-key"))
        XCTAssertTrue(ClaudeTranslator.isFatal("authentication_error: bad key"))
        XCTAssertFalse(ClaudeTranslator.isFatal("Overloaded"))
    }

    func testClaudeMalformedJSONIsSkippedNotFatal() {
        XCTAssertEqual(ClaudeTranslator.interpret("data: {not json"), .nothing)
    }

    // MARK: - OpenAI chat completions SSE

    func testOpenAITextDeltaIsExtracted() {
        let line = #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Bon"},"finish_reason":null}]}"#
        XCTAssertEqual(OpenAITextTranslator.interpret(line), .text("Bon"))
    }

    func testOpenAIDoneSentinelEndsTheStream() {
        XCTAssertEqual(OpenAITextTranslator.interpret("data: [DONE]"), .done)
    }

    func testOpenAIRoleOnlyChunkIsNothing() {
        let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
        XCTAssertEqual(OpenAITextTranslator.interpret(line), .nothing)
        XCTAssertEqual(OpenAITextTranslator.interpret(#"data: {"choices":[]}"#), .nothing)
    }

    // MARK: - Realtime events

    private func kind(_ json: String) -> RealtimeEventKind {
        let event = try! JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
        return RealtimeEventKind(from: event)
    }

    func testRealtimeEventsMatchWithAndWithoutSessionPrefix() {
        if case .translatedDelta("hi") = kind(#"{"type":"session.output_transcript.delta","delta":"hi"}"#) {} else { XCTFail() }
        if case .translatedDelta("hi") = kind(#"{"type":"response.output_text.delta","delta":"hi"}"#) {} else { XCTFail() }
        if case .translatedCompleted("done") = kind(#"{"type":"session.output_transcript.done","transcript":"done"}"#) {} else { XCTFail() }
    }

    func testRealtimeSourceTranscriptDeltasAndDoneAreDistinct() {
        if case .sourceTranscriptDelta("ho") = kind(#"{"type":"session.input_transcript.delta","delta":"ho"}"#) {} else { XCTFail() }
        if case .sourceTranscript("hola") = kind(#"{"type":"session.input_transcript.done","transcript":"hola"}"#) {} else { XCTFail() }
    }

    func testRealtimeErrorsCarryTheirMessage() {
        if case .error("bad key") = kind(#"{"type":"error","error":{"code":"invalid_api_key","message":"bad key"}}"#) {} else { XCTFail() }
        if case .error = kind(#"{"type":"session.error","error":{}}"#) {} else { XCTFail() }
    }

    func testRealtimeUnknownEventsAreOther() {
        if case .other("rate_limits.updated") = kind(#"{"type":"rate_limits.updated"}"#) {} else { XCTFail() }
    }

    // MARK: - Sentence splitting

    private func firstSentence(_ text: String) -> String? {
        OpenAIRealtimeService.sentenceEnd(in: text).map { String(text[..<$0]).trimmingCharacters(in: .whitespaces) }
    }

    func testSplitsAtTerminatorFollowedByWhitespace() {
        XCTAssertEqual(firstSentence("That works. Could we push it?"), "That works.")
        XCTAssertEqual(firstSentence("Really?! Yes"), "Really?!")
    }

    func testDoesNotSplitDecimalsInitialsOrTrailingTerminators() {
        XCTAssertNil(firstSentence("It costs 3.5 million"))
        XCTAssertNil(firstSentence("Ask J.Smith"))
        XCTAssertNil(firstSentence("Not finished yet."), "a terminator at the very end waits for what follows")
    }

    func testSplitsOnCJKPunctuation() {
        XCTAssertEqual(firstSentence("わかりました。 では"), "わかりました。")
    }
}
