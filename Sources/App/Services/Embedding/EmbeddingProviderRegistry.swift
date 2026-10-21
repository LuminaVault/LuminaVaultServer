import Configuration
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import HummingbirdFluent
import Logging

/// HER-134 — env-loaded registry that owns the per-boot text-embedding
/// adapter map and selects an active provider + fallback chain. Mirrors
/// `VisionEmbedProviderRegistry`. The active service exposed to callers
/// is already wrapped by `EmbeddingUsageTracker` (cost guard) and
/// `EmbeddingFallbackService` (chain), so consumers can keep depending
/// on the bare `EmbeddingService` protocol.
struct EmbeddingProviderRegistry {
    let active: any EmbeddingService
    let activeKind: EmbeddingProviderKind
    let fallbackKinds: [EmbeddingProviderKind]

    /// Boot-time construction. Reads `embedding.*` env, instantiates the
    /// providers that have credentials, wires the active one and any
    /// fallbacks, then wraps in the cost-guard tracker.
    static func bootstrap(
        reader: ConfigReader,
        fluent: Fluent,
        hermesHandleResolver: @escaping LocalHermesEmbeddingService.HandleResolver,
        session: URLSession = .shared,
        logger: Logger = Logger(label: "lv.embedding.registry")
    ) -> EmbeddingProviderRegistry {
        let activeRaw = reader.string(forKey: "embedding.provider", default: "deterministic")
        let activeKind = EmbeddingProviderKind(rawConfigValue: activeRaw) ?? .deterministic

        let fallbackRaw = reader.string(forKey: "embedding.fallbackChain", default: "")
        let fallbackKinds: [EmbeddingProviderKind] = fallbackRaw
            .split(separator: ",")
            .compactMap { EmbeddingProviderKind(rawConfigValue: String($0)) }
            .filter { $0 != activeKind }

        let monthlyCap = Int64(reader.int(forKey: "embedding.monthlyTokenCapDefault", default: 2_000_000))

        // Build each adapter on demand (no point holding the OpenAI client
        // if the key isn't set). The deterministic stub is always available.
        var built: [EmbeddingProviderKind: any EmbeddingService] = [
            .deterministic: DeterministicEmbeddingService(),
        ]

        let openaiKey = reader.string(forKey: "llm.provider.openai.apiKey", isSecret: true, default: "")
        if !openaiKey.isEmpty {
            let rawBase = reader.string(forKey: "llm.provider.openai.baseURL", default: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = URL(string: rawBase) ?? OpenAIEmbeddingService.defaultBaseURL
            built[.openai] = OpenAIEmbeddingService(apiKey: openaiKey, baseURL: base, session: session, logger: Logger(label: "lv.embedding.openai"))
        }

        // OpenRouter reuses the platform OpenRouter key the LLM routing reads
        // (`ProviderRegistry.loadConfigs`: canonical, legacy spelling, then the
        // `openrouter.*` aliases) so there is no second secret to seal. The
        // base URL and model are embedding-specific: the LLM's OpenRouter base
        // URL may already end in `/v1`, and the service appends `v1/embeddings`.
        if let openRouterKey = openRouterAPIKey(reader: reader) {
            let rawBase = reader.string(forKey: "embedding.openRouter.baseURL", default: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = rawBase.isEmpty ? OpenAIEmbeddingService.openRouterBaseURL : (URL(string: rawBase) ?? OpenAIEmbeddingService.openRouterBaseURL)
            let rawModel = reader.string(forKey: "embedding.openRouter.model", default: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            built[.openRouter] = OpenAIEmbeddingService(
                apiKey: openRouterKey,
                baseURL: base,
                model: rawModel.isEmpty ? OpenAIEmbeddingService.openRouterModel : rawModel,
                providerLabel: "openrouter",
                session: session,
                logger: Logger(label: "lv.embedding.openrouter")
            )
        }

        let nomicKey = reader.string(forKey: "embedding.nomic.apiKey", isSecret: true, default: "")
        if !nomicKey.isEmpty {
            built[.nomic] = NomicEmbeddingService(apiKey: nomicKey, logger: Logger(label: "lv.embedding.nomic"))
        }

        // LocalHermes has no static credential — it resolves a per-tenant
        // handle on each call. Always register.
        built[.hermesLocal] = LocalHermesEmbeddingService(
            resolveHandle: hermesHandleResolver,
            logger: Logger(label: "lv.embedding.hermesLocal")
        )

        // Pick active. If the configured provider failed to register
        // (missing key), log a loud warning and fall back to deterministic
        // so the app still boots — mirrors the TTS pattern at line 989.
        let activeInner: any EmbeddingService
        let resolvedActiveKind: EmbeddingProviderKind
        if let svc = built[activeKind] {
            activeInner = svc
            resolvedActiveKind = activeKind
        } else {
            logger.warning(
                "embedding provider \(activeKind.rawValue) requested but not configured (\(missingCredentialHint(for: activeKind))); falling back to deterministic — semantic search, recall and related memories run on hash-based fake vectors"
            )
            activeInner = built[.deterministic]!
            resolvedActiveKind = .deterministic
        }

        let fallbackPairs: [(EmbeddingProviderKind, any EmbeddingService)] = fallbackKinds.compactMap { kind in
            guard let svc = built[kind] else {
                logger.warning("embedding fallback \(kind.rawValue) not configured; dropping from chain")
                return nil
            }
            return (kind, svc)
        }

        let withFallback = EmbeddingFallbackService(
            primary: activeInner,
            primaryKind: resolvedActiveKind,
            fallbacks: fallbackPairs,
            logger: Logger(label: "lv.embedding.fallback")
        )

        let tracker = EmbeddingUsageTracker(
            inner: withFallback,
            usage: EmbeddingUsageRepository(fluent: fluent),
            monthlyCap: monthlyCap,
            logger: Logger(label: "lv.embedding.usage")
        )

        logger.info("embedding registry active=\(resolvedActiveKind.rawValue) fallbacks=\(fallbackPairs.map(\.0.rawValue).joined(separator: ",")) cap=\(monthlyCap)")
        return EmbeddingProviderRegistry(
            active: tracker,
            activeKind: resolvedActiveKind,
            fallbackKinds: fallbackPairs.map(\.0)
        )
    }

    /// The OpenRouter key exactly as the LLM routing resolves it, or nil when
    /// none of its spellings is set.
    static func openRouterAPIKey(reader: ConfigReader) -> String? {
        ProviderRegistry.loadConfigs(from: reader)
            .first { $0.kind == .openRouter }?
            .apiKey
    }

    /// Names the env var an operator has to set, so the boot warning says
    /// what to fix rather than only that something is wrong.
    static func missingCredentialHint(for kind: EmbeddingProviderKind) -> String {
        switch kind {
        case .openai: "LLM_PROVIDER_OPENAI_API_KEY is empty"
        case .openRouter: "no OpenRouter key: LLM_PROVIDER_OPEN_ROUTER_API_KEY / OPENROUTER_API_KEY / OPENROUTER_FALLBACK_API_KEY are all empty"
        case .nomic: "EMBEDDING_NOMIC_API_KEY is empty"
        case .hermesLocal, .deterministic: "adapter not registered"
        }
    }
}
