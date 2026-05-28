import Foundation

/// HER-134 — classified embedding failures so the fallback chain can route:
/// `.transient` / `.network` → try next provider; `.permanent` → rethrow.
/// `.capExceeded` is surfaced by `EmbeddingUsageTracker` to short-circuit
/// before any provider HTTP call. `.dimMismatch` guards against a provider
/// returning a vector that doesn't match the column width.
enum EmbeddingProviderError: Error, Equatable {
    case transient(reason: String)
    case network(reason: String)
    case permanent(reason: PermanentReason)
    case capExceeded(tenantID: UUID, monthlyTokens: Int64, cap: Int64)
    case dimMismatch(expected: Int, got: Int)

    enum PermanentReason: String, Equatable {
        case missingAPIKey
        case authRejected
        case requestRejected
        case decodeFailed
        case endpointMissing
        case providerNotRegistered
        case allProvidersFailed
    }

    /// True if a fallback chain should advance to the next provider.
    var isRecoverable: Bool {
        switch self {
        case .transient, .network: true
        case .permanent, .capExceeded, .dimMismatch: false
        }
    }
}
