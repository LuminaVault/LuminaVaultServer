import Foundation
import LuminaVaultShared

/// The zero-cost fallback lane: what we route to when a user is neither paying
/// nor bringing their own key, and when platform managed inference is gone.
///
/// Two legs, tried in order. The OpenRouter leg is a `:free` slug on the
/// platform OpenRouter key — no consumable balance, so it is the renewable
/// resource and goes first. The NVIDIA NIM leg burns a finite pool of free
/// signup credits, so it is the reserve.
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

    /// `nvidia/nemotron-3-ultra-550b-a55b:free` — 1,000,000 token context,
    /// $0 in / $0 out, tool-calling supported. Verified against the OpenRouter
    /// models API on 2026-08-08.
    static let defaultOpenRouterModel = "nvidia/nemotron-3-ultra-550b-a55b:free"

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
        nvidiaModel: String = defaultNvidiaModel,
        preferring leg: Leg? = nil
    ) -> [Route] {
        let all = [
            Route(leg: .openRouterFree, provider: .openRouter, model: openRouterModel),
            Route(leg: .nvidiaDirect, provider: .nvidia, model: nvidiaModel),
        ]
        guard let leg, let index = all.firstIndex(where: { $0.leg == leg }) else { return all }
        return [all[index]] + all.enumerated().filter { $0.offset != index }.map(\.element)
    }
}
