import Foundation
import Hummingbird

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let messages: [ChatMessage]
    let model: String?
    let temperature: Double?
}

/// Mirrors the OpenAI chat-completions response shape that the Hermes
/// gateway is expected to emit. Fields beyond the ones we read into
/// `ChatResponse.message` are still surfaced via `raw` for transparency.
struct HermesUpstreamChoice: Codable {
    let index: Int?
    let message: ChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct HermesUpstreamUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct HermesUpstreamResponse: Codable {
    let id: String
    let object: String?
    let created: Int?
    let model: String
    let choices: [HermesUpstreamChoice]
    let usage: HermesUpstreamUsage?
}

struct ChatResponse: Codable, ResponseEncodable {
    let id: String
    let model: String
    let message: ChatMessage
    let raw: HermesUpstreamResponse
}
