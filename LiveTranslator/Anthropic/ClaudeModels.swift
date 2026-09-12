import Foundation

/// Wire types for the Anthropic Messages API.

struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    /// Sonnet 5 and Opus 5 think by default. A one-sentence translation gains
    /// nothing from it and pays the latency, so it is turned off explicitly.
    /// Haiku 4.5 doesn't think unless asked, so the field is omitted there.
    struct Thinking: Encodable {
        let type = "disabled"
    }

    let model: String
    let max_tokens: Int
    let stream: Bool
    let system: String
    let messages: [Message]
    let thinking: Thinking?

    init(model: ClaudeModel, systemPrompt: String, userText: String) {
        self.model = model.rawValue
        // Subtitle-length output; a spoken utterance never needs more.
        self.max_tokens = 1024
        self.stream = true
        self.system = systemPrompt
        self.messages = [Message(role: "user", content: userText)]
        self.thinking = model.thinkingOnByDefault ? Thinking() : nil
    }
}

/// One server-sent event from a streaming response. Deliberately loose — we
/// care about text deltas, the stop reason, and errors, and ignore the rest.
struct StreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stop_reason: String?
    }

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }

    let type: String
    let delta: Delta?
    let error: APIError?
}

/// A non-200 response body.
struct APIErrorResponse: Decodable {
    struct Body: Decodable {
        let type: String?
        let message: String
    }
    let error: Body
}
