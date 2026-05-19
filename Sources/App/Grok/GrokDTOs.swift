import Foundation
import Hummingbird

// HER-240c — server-local wire DTOs for `/v1/grok/*`. Server-local for the
// same reason HER-240a's xai DTOs are local (LuminaVaultShared version
// graph churn). iOS client mirrors these shapes; both move to shared once
// the package settles.

struct GrokChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
}

/// POST /v1/grok/chat — minimal chat-completions style request. Streamed
/// when `stream: true` (SSE). Mirrors the OpenAI/Hermes chat shape so the
/// per-tenant Hermes container forwards it to xAI without translation.
struct GrokChatRequest: Codable, Sendable {
    let messages: [GrokChatMessage]
    let model: String?
    let stream: Bool?
    let maxTokens: Int?
}

struct GrokChatResponse: Codable, Sendable, ResponseEncodable {
    /// Pass-through synthesised reply text. Tool calls + reasoning chain
    /// are out of scope for the MVP shape; HER-240c follow-up will widen
    /// the response when client surfaces actually consume them.
    let answer: String
    let model: String
    let usage: GrokUsage?
}

struct GrokUsage: Codable, Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
}

/// POST /v1/grok/x-search — Grok's `x_search` tool. Matches the params
/// documented at hermes-agent.nousresearch.com/docs/user-guide/features/x-search.
struct GrokXSearchRequest: Codable, Sendable {
    let query: String
    let allowedXHandles: [String]?
    let excludedXHandles: [String]?
    let fromDate: String?
    let toDate: String?
    let enableImageUnderstanding: Bool?
    let enableVideoUnderstanding: Bool?
}

struct GrokXSearchCitation: Codable, Sendable, Equatable {
    let url: String
    let title: String?
    let publishedAt: Date?
}

struct GrokXSearchResponse: Codable, Sendable, ResponseEncodable {
    let answer: String
    let citations: [GrokXSearchCitation]
    let model: String
}

/// POST /v1/grok/vision — multimodal request. `imageURLs` accepts public
/// HTTPS image URLs; base64 data URIs land in a follow-up.
struct GrokVisionRequest: Codable, Sendable {
    let prompt: String
    let imageURLs: [String]
}

struct GrokVisionResponse: Codable, Sendable, ResponseEncodable {
    let answer: String
    let model: String
}

/// POST /v1/grok/tts — text → audio. MVP returns 501 unless the server
/// has an upstream TTS provider configured; client surfaces the
/// `"coming_soon"` error code as a placeholder UX. Body shape lands now
/// so the iOS surface can wire up without churn later.
struct GrokTTSRequest: Codable, Sendable {
    let text: String
    let voice: String?
}

struct GrokTTSResponse: Codable, Sendable, ResponseEncodable {
    /// Base64-encoded audio bytes. MVP serves a single MP3/WAV blob;
    /// chunked streaming is a follow-up if/when xAI publishes the audio
    /// endpoint we can proxy to.
    let audioBase64: String
    let mimeType: String
}
