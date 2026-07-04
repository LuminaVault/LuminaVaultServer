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
    ///
    /// HER-240 — `.network` distinguishes:
    /// - `upstream_timeout` — `URLError.timedOut` (e.g. LLM stalled past adapter timeout)
    /// - `upstream_unreachable` — connection-failure URLErrors (DNS, no route, dropped link)
    /// - `network` — any other URLError or non-URLError underlying
    ///
    /// These string keys are STABLE — clients consume them as telemetry
    /// labels and iOS localization roots. Add new variants; do not rename.
    var reasonCode: String {
        switch self {
        case .creditExhausted: "credit_exhausted"
        case let .transient(_, status, _) where status == 429: "rate_limit"
        case .transient: "upstream_error"
        case let .network(_, underlying):
            switch Self.underlyingKind(of: underlying) {
            case .timeout: "upstream_timeout"
            case .unreachable: "upstream_unreachable"
            case .other: "network"
            }
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
        case let .transient(_, status, body):
            return "\(providerName) is having trouble responding.\(Self.detailSuffix(status: status, body: body))"
        case let .network(_, underlying):
            switch Self.underlyingKind(of: underlying) {
            case .timeout: return "\(providerName) timed out responding."
            case .unreachable, .other: return "Couldn't reach \(providerName)."
            }
        case let .permanent(_, status, body):
            return "\(providerName) rejected the request.\(Self.detailSuffix(status: status, body: body))"
        }
    }

    /// Turn a captured upstream error body into a short, user-facing suffix so
    /// chat shows the real reason ("models/gemini-3-pro-preview is not found")
    /// instead of a generic "rejected". Pulls `error.message` out of the common
    /// provider JSON shape (`{"error":{"message":…}}` — Gemini, OpenAI,
    /// OpenRouter), else truncates the raw preview. Empty → just the status.
    private static func detailSuffix(status: Int, body: String?) -> String {
        if let message = extractUpstreamMessage(from: body), !message.isEmpty {
            return " (\(status)) \(message)"
        }
        return " (\(status))"
    }

    static func extractUpstreamMessage(from body: String?) -> String? {
        guard let body else { return nil }
        if
            let data = body.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return Self.clip(m) }
            if let errStr = obj["error"] as? String { return Self.clip(errStr) }
            if let m = obj["message"] as? String { return Self.clip(m) }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Self.clip(trimmed)
    }

    private static func clip(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }

    // MARK: - URLError classification

    /// Coarse classification of a `.network` case's underlying error.
    /// Single source of truth for `reasonCode` and `userMessage`.
    private enum URLErrorKind {
        case timeout
        case unreachable
        case other
    }

    private static func underlyingKind(of underlying: any Error) -> URLErrorKind {
        guard let urlError = underlying as? URLError else { return .other }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost,
             .notConnectedToInternet,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost:
            return .unreachable
        default:
            return .other
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
        case .nvidia: "NVIDIA NIM"
        case .nous: "Nous"
        case .custom: "Custom"
        }
    }
}
