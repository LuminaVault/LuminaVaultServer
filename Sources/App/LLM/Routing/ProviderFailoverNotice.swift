import Foundation
import LuminaVaultShared

/// HER-252 — describes a single failover transition in
/// `RoutedLLMTransport`. Built when candidate `i` throws a recoverable
/// `ProviderError` and candidate `i+1` is about to be tried. Published
/// through `FailoverNoticeContext.sink` so controllers can yield a
/// matching `.fallback` SSE event, and through
/// `ProviderFailoverLogger` for `provider_failover_events` telemetry.
struct ProviderFailoverNotice: Sendable {
    let originalProvider: ProviderKind
    let originalModel: String
    let fallbackProvider: ProviderKind
    let fallbackModel: String
    let reasonCode: String
    let userMessage: String
    let statusCode: Int?
    let bodyPreview: String?
    let source: TelemetrySource

    /// Tag attached to `provider_failover_events.source` so ops can
    /// segment "managed default Hermes failures" vs "users running their
    /// own gateway". Tagged from `LLMRoutingContext.currentResolution`.
    enum TelemetrySource: String, Sendable {
        case hosted
        case byo
    }

    /// Project the notice onto the wire-format DTO surfaced over SSE.
    func wireDTO() -> ProviderFallbackNoticeDTO {
        ProviderFallbackNoticeDTO(
            originalProvider: originalProvider.toShared() ?? .openai,
            originalModel: originalModel,
            fallbackProvider: fallbackProvider.toShared() ?? .openai,
            fallbackModel: fallbackModel,
            reasonCode: reasonCode,
            userMessage: userMessage,
        )
    }
}

/// HER-252 — task-local sink the chat / query controllers attach before
/// invoking the LLM transport. `RoutedLLMTransport` calls
/// `FailoverNoticeContext.sink?(notice)` on each successful failover.
/// Controllers wire the sink to `continuation.yield(.fallback(...))` so
/// the SSE stream surfaces the notice in real time.
///
/// Task-local + optional so non-streaming surfaces (kb-compile, query's
/// non-streaming endpoint, the test endpoint) can leave the sink nil
/// and the transport quietly skips publication.
enum FailoverNoticeContext {
    @TaskLocal static var sink: (@Sendable (ProviderFailoverNotice) -> Void)?
}

extension ProviderKind {
    /// Map a server-internal `ProviderKind` onto a Shared `ProviderID`
    /// for over-the-wire transmission. Returns `nil` for providers that
    /// are not user-credential targets (`hermesGateway`, `gemini`,
    /// `together`, `groq`, `fireworks`, `deepInfra`, `deepseekDirect`,
    /// `deepseek`, `kimi`). Such failovers are still logged but not
    /// surfaced via the SSE `.fallback` event (clients only know about
    /// the user-facing `ProviderID` set).
    func toShared() -> ProviderID? {
        switch self {
        case .xai: .xai
        case .anthropic: .anthropic
        case .openai: .openai
        case .openRouter: .openRouter
        case .ollama: .ollama
        default: nil
        }
    }
}
