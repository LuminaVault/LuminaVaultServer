import Foundation

/// HER-165 — uniform interface every upstream LLM provider implements.
/// `HermesGatewayAdapter` is the only landed impl today; HER-162..HER-164
/// add Together / Groq / OpenRouter adapters with the same shape.
///
/// Implementations:
/// - MUST translate the OpenAI chat-completions wire shape to / from the
///   provider's native format. Callers hand in a JSON `payload` already
///   shaped per the OpenAI spec.
/// - MUST throw `ProviderError` (never bare `URLError` etc.) so the
///   dispatcher can classify failover.
/// - SHOULD NOT retry internally — the dispatcher owns retry / failover.
protocol ProviderAdapter: Sendable {
    var kind: ProviderKind { get }

    /// Send a single chat-completions request.
    /// - `sessionKey`: tenant UUID string. Forwarded as `X-Hermes-Session-Key`
    ///   by Hermes-style adapters for per-tenant memory scoping. Non-Hermes
    ///   providers ignore it.
    /// - `sessionID`: optional conversation continuity ID. Forwarded as
    ///   `X-Hermes-Session-Id` when non-nil. One-shot tool calls pass nil.
    func chatCompletions(payload: Data, sessionKey: String, sessionID: String?) async throws -> Data
    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata
}

/// Optional extension for providers that can return OpenAI-compatible
/// `text/event-stream` chat deltas natively. The routed stream service uses
/// this when available and keeps the single-shot fallback for providers that
/// only implement `ProviderAdapter`.
protocol StreamingProviderAdapter: ProviderAdapter {
    func chatCompletionsStream(
        payload: Data,
        sessionKey: String,
        sessionID: String?
    ) async throws -> AsyncThrowingStream<ChatStreamChunk, Error>
}

extension ProviderAdapter {
    func chatCompletionsWithMetadata(payload: Data, sessionKey: String, sessionID: String?) async throws -> HermesChatTransportMetadata {
        let data = try await chatCompletions(payload: payload, sessionKey: sessionKey, sessionID: sessionID)
        return HermesChatTransportMetadata(data: data, headers: [:])
    }
}
