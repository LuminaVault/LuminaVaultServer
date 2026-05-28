import Configuration
import Foundation
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
        logger: Logger = Logger(label: "lv.embedding.registry"),
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
            built[.openai] = OpenAIEmbeddingService(apiKey: openaiKey, baseURL: base, logger: Logger(label: "lv.embedding.openai"))
        }

        let nomicKey = reader.string(forKey: "embedding.nomic.apiKey", isSecret: true, default: "")
        if !nomicKey.isEmpty {
            built[.nomic] = NomicEmbeddingService(apiKey: nomicKey, logger: Logger(label: "lv.embedding.nomic"))
        }

        // LocalHermes has no static credential — it resolves a per-tenant
        // handle on each call. Always register.
        built[.hermesLocal] = LocalHermesEmbeddingService(
            resolveHandle: hermesHandleResolver,
            logger: Logger(label: "lv.embedding.hermesLocal"),
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
            logger.warning("embedding provider \(activeKind.rawValue) requested but not configured; falling back to deterministic")
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
            logger: Logger(label: "lv.embedding.fallback"),
        )

        let tracker = EmbeddingUsageTracker(
            inner: withFallback,
            usage: EmbeddingUsageRepository(fluent: fluent),
            monthlyCap: monthlyCap,
            logger: Logger(label: "lv.embedding.usage"),
        )

        logger.info("embedding registry active=\(resolvedActiveKind.rawValue) fallbacks=\(fallbackPairs.map(\.0.rawValue).joined(separator: ",")) cap=\(monthlyCap)")
        return EmbeddingProviderRegistry(
            active: tracker,
            activeKind: resolvedActiveKind,
            fallbackKinds: fallbackPairs.map(\.0),
        )
    }
}
