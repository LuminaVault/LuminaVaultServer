import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import NIOCore

/// Routes the user-facing chat **stream** by mode:
///
/// - **managed** → delegate to `fallback` (the central Hermes gateway,
///   `DefaultHermesLLMStreamService`). True token streaming + Hermes agentic
///   loop. Unchanged behaviour.
/// - **byok** → `RoutedLLMTransport.chatStream` (P2) — resolves the
///   tenant's own provider key + model, streams tokens natively per
///   provider (OpenAI-compat SSE, Anthropic Messages SSE, Gemini
///   `alt=sse`, Ollama NDJSON), and fails over across the fallback chain
///   until the first token arrives.
///
/// HER-37 left streaming on the gateway only, so the BYOK toggle changed only
/// the non-streaming paths and chat silently used the managed model
/// (qwen/openrouter) → 402 → empty turn. This closes that gap.
///
/// Requires `LLMRoutingContext.currentUser` to be bound by the caller so the
/// routed adapters can resolve the per-tenant credential — `ConversationController`
/// binds it around `chatStream(...)`, and the work `Task` created here captures
/// the task-local at creation time.
struct RoutedHermesLLMStreamService: HermesLLMStreamService {
    /// Managed-mode upstream (central Hermes gateway).
    let fallback: any HermesLLMStreamService
    /// BYOK transport — direct-to-provider with key resolution + failover.
    let transport: any HermesChatTransport
    let preferences: UserLLMPreferenceRepository
    let logger: Logger

    private let byokCounter = Counter(label: "luminavault.llm.chat.stream.byok")
    private let byokFailureCounter = Counter(label: "luminavault.llm.chat.stream.byok.failure")

    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                if let strategy = LLMRoutingContext.parallelStrategy {
                    logger.info("chat stream routed to multi-model executor", metadata: ["strategy": .string(strategy.rawValue)])
                    let payload = try Self.makeOpenAIPayload(
                        model: request.model ?? "router-auto",
                        request: request
                    )
                    for try await chunk in transport.chatStream(
                        payload: payload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } else if let model = await byokModel(sessionKey: sessionKey) {
                    byokCounter.increment()
                    logger.info("chat stream routed to BYOK provider", metadata: ["model": .string(model)])
                    let payload = try Self.makeOpenAIPayload(model: model, request: request)
                    // P2 — true per-token streaming. RoutedLLMTransport walks
                    // the user's fallback chain and only fails over before
                    // the first token; adapters without native streaming
                    // fall back to a single terminal chunk (old behaviour).
                    for try await chunk in transport.chatStream(
                        payload: payload,
                        sessionKey: sessionKey,
                        sessionID: sessionID
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } else {
                    for try await chunk in fallback.chatStream(
                        sessionKey: sessionKey,
                        sessionID: sessionID,
                        request: request
                    ) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
            } catch {
                byokFailureCounter.increment()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    // MARK: - Resolution

    /// Returns the tenant's BYOK primary model id when they are in BYOK mode,
    /// else nil (→ caller delegates to the managed gateway). The actual key +
    /// provider routing is resolved downstream by `RoutedLLMTransport` /
    /// `UserPreferenceModelRouter` via `LLMRoutingContext.currentUser`.
    private func byokModel(sessionKey: String) async -> String? {
        guard
            let tenantID = UUID(uuidString: sessionKey),
            let pref = try? await preferences.get(tenantID: tenantID),
            pref.mode == .byok
        else { return nil }
        return pref.primaryModel.isEmpty ? nil : pref.primaryModel
    }

    /// Encode an OpenAI-style chat payload from a `ChatRequest`, overriding the
    /// model with the tenant's BYOK selection.
    static func makeOpenAIPayload(model: String, request: ChatRequest) throws -> Data {
        struct Payload: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double?
        }
        return try JSONEncoder().encode(
            Payload(model: model, messages: request.messages, temperature: request.temperature)
        )
    }

    /// Pull `choices[0].message.content` out of an OpenAI chat-completions
    /// response. Empty string when absent (caller's empty-completion policy
    /// then surfaces it as an error event rather than a blank turn).
    static func extractContent(from data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return "" }
        return content
    }
}
