import Foundation

/// HER-134 — selectable text-embedding providers. `deterministic` is the
/// hash-based dev/test stub that ships in `DeterministicEmbeddingService`;
/// the other three back the protocol with real HTTP impls.
enum EmbeddingProviderKind: String, CaseIterable, Sendable, Hashable {
    case openai
    case hermesLocal
    case nomic
    case deterministic

    init?(rawConfigValue raw: String) {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "openai": self = .openai
        case "hermeslocal", "hermes_local", "hermes-local", "local", "localhermes": self = .hermesLocal
        case "nomic": self = .nomic
        case "deterministic", "dev", "stub": self = .deterministic
        default: return nil
        }
    }
}
