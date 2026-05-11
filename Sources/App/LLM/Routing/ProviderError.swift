import Foundation

/// HER-165 — typed error every `ProviderAdapter` throws. The dispatcher
/// (`RoutedLLMTransport`) decides whether to fall over to the next
/// candidate based on which case fires.
///
/// Failover policy:
/// - `.transient`  → try next candidate (429, 5xx, gateway timeout)
/// - `.network`    → try next candidate (DNS, TLS, connection reset)
/// - `.permanent`  → stop. Bubble up. 4xx (except 429) means our payload
///   is wrong and another provider won't fix it.
enum ProviderError: Error, Sendable {
    case transient(provider: ProviderKind, status: Int, body: String?)
    case permanent(provider: ProviderKind, status: Int, body: String?)
    case network(provider: ProviderKind, underlying: any Error)

    /// True when the dispatcher should try the next fallback candidate.
    var isRecoverable: Bool {
        switch self {
        case .transient, .network: return true
        case .permanent: return false
        }
    }

    var provider: ProviderKind {
        switch self {
        case .transient(let p, _, _): return p
        case .permanent(let p, _, _): return p
        case .network(let p, _): return p
        }
    }
}
