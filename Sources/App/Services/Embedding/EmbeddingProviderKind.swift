import Foundation

/// HER-134 — selectable text-embedding providers. `deterministic` is the
/// hash-based dev/test stub that ships in `DeterministicEmbeddingService`;
/// the others back the protocol with real HTTP impls. `openRouter` is the
/// OpenAI-compatible `/v1/embeddings` endpoint on OpenRouter, keyed with the
/// same platform OpenRouter key the LLM routing already uses.
enum EmbeddingProviderKind: String, CaseIterable, Hashable {
    case openai
    case openRouter
    case hermesLocal
    case nomic
    case deterministic

    init?(rawConfigValue raw: String) {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "openai": self = .openai
        case "openrouter", "open_router", "open-router": self = .openRouter
        case "hermeslocal", "hermes_local", "hermes-local", "local", "localhermes": self = .hermesLocal
        case "nomic": self = .nomic
        case "deterministic", "dev", "stub": self = .deterministic
        default: return nil
        }
    }
}
