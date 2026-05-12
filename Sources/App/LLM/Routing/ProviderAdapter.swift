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

    /// Send a single chat-completions request. `profileUsername` is
    /// threaded through for Hermes-style per-tenant profile routing; non-
    /// Hermes providers may ignore it.
    func chatCompletions(payload: Data, profileUsername: String) async throws -> Data
    func chatCompletionsWithMetadata(payload: Data, profileUsername: String) async throws -> HermesChatTransportMetadata
}

extension ProviderAdapter {
    func chatCompletionsWithMetadata(payload: Data, profileUsername: String) async throws -> HermesChatTransportMetadata {
        let data = try await chatCompletions(payload: payload, profileUsername: profileUsername)
        return HermesChatTransportMetadata(data: data, headers: [:])
    }
}
