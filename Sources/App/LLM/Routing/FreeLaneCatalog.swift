import Foundation
import LuminaVaultShared

/// The zero-cost fallback lane: what we route to when a user is neither paying
/// nor bringing their own key, and when platform managed inference is gone.
///
/// Two legs and three routes, tried in order. The OpenRouter leg is a pair of
/// `:free` slugs on the platform OpenRouter key — no consumable balance, so it
/// is the renewable resource and goes first. The NVIDIA NIM leg burns a finite
/// pool of free signup credits, so it is the reserve.
///
/// **Both OpenRouter slugs deliberately share `Leg.openRouterFree`.**
/// `FreeLaneGate` meters one counter per leg, and OpenRouter's `:free` allowance
/// is account-wide across every `:free` slug (50 requests/day un-topped-up,
/// 1000 after a $10 purchase) — not per model. A second `Leg` case would give
/// the second slug its own counter and let the lane spend twice the allowance,
/// producing exactly the 429s the gate exists to prevent. The second slug buys
/// resilience against a single model being down or per-minute throttled; it does
/// not buy capacity.
///
/// Deliberately kept OUT of `RouterModelCatalog.entries`. Entries there are
/// expanded into the Auto pool for every usable provider
/// (`AvailableModelPoolBuilder.expand`), so a `:free` slug in the catalog gets
/// picked for *paying* users under cost-first scoring and burns the platform's
/// account-wide free-model allowance on the people funding us.
enum FreeLaneCatalog {
    enum Leg: String, Sendable, Hashable, CaseIterable, Codable {
        /// Platform OpenRouter key, `:free` slug. No balance consumed.
        case openRouterFree
        /// Platform NVIDIA NIM key against `integrate.api.nvidia.com`.
        case nvidiaDirect
    }

    struct Route: Sendable, Equatable {
        let leg: Leg
        let provider: ProviderID
        let model: String
    }

    /// `z-ai/glm-5.2:free` — 256,000 token context, $0 in / $0 out,
    /// tool-calling supported. Verified against the OpenRouter models API on
    /// 2026-08-21. Primary because it is materially faster than the Nemotron
    /// ultra it replaced, and 256K covers all but long-document work.
    static let defaultOpenRouterModel = "z-ai/glm-5.2:free"

    /// Second hop on the *same* OpenRouter key and the *same* gate counter.
    /// 1,000,000 token context — carries long-document requests the primary
    /// cannot, at higher latency.
    static let defaultOpenRouterSecondaryModel = "nvidia/nemotron-3-ultra-550b-a55b:free"

    /// NIM serves the same family under its own catalogue. The `:free` suffix
    /// is an OpenRouter *routing directive*, not part of the model id — sending
    /// it to `integrate.api.nvidia.com` 404s the model, so the two legs
    /// necessarily carry different ids.
    static let defaultNvidiaModel = "nvidia/nemotron-3-super-120b-a12b"

    /// Hermes Agent refuses to start a turn when either the primary model or
    /// `auxiliary.compression` advertises less than this, so every free-lane
    /// slug has to clear it. See `docs/CONFIG.md`, "Managed Hermes context
    /// window".
    static let hermesMinimumContextWindow = 64000

    /// Failover order. `preferring` promotes a leg the gate has already granted
    /// to primary while keeping the other as the in-flight fallback.
    static func routes(
        openRouterModel: String = defaultOpenRouterModel,
        openRouterSecondaryModel: String = defaultOpenRouterSecondaryModel,
        nvidiaModel: String = defaultNvidiaModel,
        preferring leg: Leg? = nil
    ) -> [Route] {
        let all = [
            Route(leg: .openRouterFree, provider: .openRouter, model: openRouterModel),
            Route(leg: .openRouterFree, provider: .openRouter, model: openRouterSecondaryModel),
            Route(leg: .nvidiaDirect, provider: .nvidia, model: nvidiaModel),
        ]
        // Promote every route on the granted leg, preserving relative order, so
        // a granted OpenRouter claim keeps both of its slugs as in-flight hops.
        guard let leg, all.contains(where: { $0.leg == leg }) else { return all }
        return all.filter { $0.leg == leg } + all.filter { $0.leg != leg }
    }
}
