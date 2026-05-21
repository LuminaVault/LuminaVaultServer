import Foundation

/// HER-252 — pure classifier that maps an upstream non-2xx response to a
/// `ProviderError` case. Centralizes the failover policy so every
/// adapter classifies the same way and the rules are easy to unit-test.
///
/// Policy:
/// - 401              → `.permanent` (our auth is bad; another provider
///   won't fix it).
/// - 402              → `.creditExhausted` (Payment Required is the
///   canonical credit-exhaustion signal across providers).
/// - 403 + credit/quota/billing marker in body → `.creditExhausted`
///   (xAI, OpenAI, Anthropic all surface credit exhaustion as 403 with
///   the marker inside the body, not the status code).
/// - 403 (other)      → `.permanent` (auth/forbidden, not a credit
///   issue).
/// - 404, 4xx (other) → `.permanent` (payload/route problem).
/// - 408, 425         → `.transient` (request timeout / too-early
///   retryable).
/// - 429              → `.transient` (rate-limited; try next provider).
/// - 5xx              → `.transient` (upstream broken).
/// - other            → `.permanent` (default conservative).
enum ProviderErrorClassifier {
    /// Marker substrings that flip a 403 (or 402) into `.creditExhausted`.
    /// Lowercased; matched against the lowercased body preview. Kept as a
    /// single shared list so tests pin down the exact tokens used.
    static let creditMarkers: [String] = [
        "credit",
        "insufficient_quota",
        "insufficient quota",
        "quota_exceeded",
        "quota exceeded",
        "out_of_credits",
        "out of credits",
        "billing",
        "payment_required",
        "payment required",
        "insufficient_balance",
        "insufficient balance",
    ]

    /// Classify a non-2xx response. The caller is expected to have
    /// already handled 2xx (returning success) and network-layer
    /// failures (which throw `.network` directly).
    ///
    /// `body` is the raw response data; the classifier itself trims it
    /// to a 2KB preview before pattern matching so the function is safe
    /// to call with a multi-megabyte error body. The preview is also
    /// what gets stored on the thrown `ProviderError` so logs and
    /// telemetry don't blow up on huge upstream errors.
    static func classify(provider: ProviderKind, status: Int, body: Data?) -> ProviderError {
        let preview = body.flatMap { String(data: $0.prefix(2048), encoding: .utf8) }
        let lower = preview?.lowercased() ?? ""

        switch status {
        case 200 ..< 300:
            // Called on a success — adapter bug. Treat as permanent
            // so it shows up in logs rather than silently failing over.
            return .permanent(provider: provider, status: status, body: preview)
        case 401:
            return .permanent(provider: provider, status: status, body: preview)
        case 402:
            return .creditExhausted(provider: provider, status: status, body: preview)
        case 403:
            if containsCreditMarker(lower) {
                return .creditExhausted(provider: provider, status: status, body: preview)
            }
            return .permanent(provider: provider, status: status, body: preview)
        case 408, 425, 429:
            return .transient(provider: provider, status: status, body: preview)
        case 500 ..< 600:
            return .transient(provider: provider, status: status, body: preview)
        default:
            return .permanent(provider: provider, status: status, body: preview)
        }
    }

    static func containsCreditMarker(_ body: String) -> Bool {
        creditMarkers.contains { body.contains($0) }
    }
}
