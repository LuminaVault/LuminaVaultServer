import Foundation

/// HER-165 — typed error every `ProviderAdapter` throws. The dispatcher
/// (`RoutedLLMTransport`) decides whether to fall over to the next
/// candidate based on which case fires.
///
/// Failover policy:
/// - `.transient`        → try next candidate (429, 5xx, gateway timeout)
/// - `.network`          → try next candidate (DNS, TLS, connection reset)
/// - `.creditExhausted`  → try next candidate (402, or 403 with a body
///   marker like `insufficient_quota` / `credit` / `billing`). HER-252
///   — credit exhaustion on a paid upstream is recoverable: another
///   provider in the user's chain can serve the request.
/// - `.permanent`        → stop. Bubble up. 4xx (except 429 / credit-
///   exhaustion variants) means our payload is wrong (or our auth) and
///   another provider won't fix it.
enum ProviderError: Error {
    case transient(provider: ProviderKind, status: Int, body: String?)
    case permanent(provider: ProviderKind, status: Int, body: String?)
    case network(provider: ProviderKind, underlying: any Error)
    case creditExhausted(provider: ProviderKind, status: Int, body: String?)

    /// True when the dispatcher should try the next fallback candidate.
    var isRecoverable: Bool {
        switch self {
        case .transient, .network, .creditExhausted: true
        case .permanent: false
        }
    }

    var provider: ProviderKind {
        switch self {
        case let .transient(p, _, _): p
        case let .permanent(p, _, _): p
        case let .network(p, _): p
        case let .creditExhausted(p, _, _): p
        }
    }

    /// HER-252 — stable, machine-readable tag emitted on telemetry rows
    /// (`provider_failover_events.error_code`) and SSE `.fallback`
    /// notices so clients can localize the message without parsing
    /// status codes.
    var reasonCode: String {
        switch self {
        case .creditExhausted: "credit_exhausted"
        case let .transient(_, status, _) where status == 429: "rate_limit"
        case .transient: "upstream_error"
        case .network: "network"
        case .permanent: "upstream_rejected"
        }
    }

    /// HER-252 — short, user-facing string surfaced verbatim on the
    /// SSE `.fallback` event. The provider's display name is folded in
    /// so chat banners read naturally ("Your Grok credits are exhausted.
    /// Falling back to …").
    var userMessage: String {
        let providerName = provider.userFacingName
        switch self {
        case .creditExhausted:
            return "Your \(providerName) credits are exhausted."
        case let .transient(_, status, _) where status == 429:
            return "\(providerName) is rate-limiting us."
        case .transient:
            return "\(providerName) is having trouble responding."
        case .network:
            return "Couldn't reach \(providerName)."
        case .permanent:
            return "\(providerName) rejected the request."
        }
    }
}

extension ProviderKind {
    /// HER-252 — display name surfaced to users in fallback banners.
    /// Server-side only; Shared `ProviderID` carries a separate
    /// user-facing label for client-rendered strings.
    var userFacingName: String {
        switch self {
        case .hermesGateway: "Hermes"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .together: "Together"
        case .groq: "Groq"
        case .fireworks: "Fireworks"
        case .deepInfra: "DeepInfra"
        case .deepseekDirect: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .deepseek: "DeepSeek"
        case .kimi: "Kimi"
        case .ollama: "Ollama"
        case .xai: "Grok"
        }
    }
}
