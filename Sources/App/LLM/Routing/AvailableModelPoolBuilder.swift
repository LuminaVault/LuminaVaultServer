import Foundation
import LuminaVaultShared

/// Builds the set of (provider, model) candidates Auto (Smart) may choose from,
/// scoped to credentials the user (or managed deployment) can actually call.
enum AvailableModelPoolBuilder {
    struct Input: Sendable {
        let mode: LLMBrainMode
        /// Effective routing policy. `autoSmart` restricts the pool to the
        /// OpenRouter catalog: managed Auto rides the shared gateway's system
        /// key, BYOK Auto requires the tenant's own OpenRouter credential.
        let policy: LLMRoutingPolicy
        let profileRoutes: [RouterModelRouteDTO]
        let allowedProviders: [ProviderID]
        let blockedProviders: [ProviderID]
        /// Providers the tenant has a usable credential for (BYOK).
        let credentialedProviders: Set<ProviderID>
        /// Providers the deployment registry can call without user keys (managed).
        let deploymentEnabledProviders: Set<ProviderID>
        let minTier: RouterModelTier

        init(
            mode: LLMBrainMode,
            policy: LLMRoutingPolicy = .balanced,
            profileRoutes: [RouterModelRouteDTO],
            allowedProviders: [ProviderID],
            blockedProviders: [ProviderID],
            credentialedProviders: Set<ProviderID>,
            deploymentEnabledProviders: Set<ProviderID>,
            minTier: RouterModelTier
        ) {
            self.mode = mode
            self.policy = policy
            self.profileRoutes = profileRoutes
            self.allowedProviders = allowedProviders
            self.blockedProviders = blockedProviders
            self.credentialedProviders = credentialedProviders
            self.deploymentEnabledProviders = deploymentEnabledProviders
            self.minTier = minTier
        }
    }

    /// Expand + filter candidates. Empty means no usable model for this policy.
    static func build(_ input: Input) -> [RouterModelRouteDTO] {
        var candidates: [RouterModelRouteDTO] = []
        var seen = Set<String>()

        func append(_ route: RouterModelRouteDTO) {
            guard !seen.contains(route.id) else { return }
            if input.blockedProviders.contains(route.provider) {
                return
            }
            if !input.allowedProviders.isEmpty, !input.allowedProviders.contains(route.provider) {
                return
            }
            seen.insert(route.id)
            candidates.append(route)
        }

        // Providers the user (or deployment) can actually call.
        let usableProviders: Set<ProviderID> = switch (input.mode, input.policy) {
        case (.managed, .autoSmart):
            // Managed Auto always routes over OpenRouter: the shared Hermes
            // gateway holds the system key, so no server-side registry
            // credential is required for it to be callable.
            [.openRouter]
        case (.managed, _):
            // Managed may use deployment keys + any user keys the tenant also added.
            input.deploymentEnabledProviders.union(input.credentialedProviders)
        case (.byok, .autoSmart):
            // BYOK Auto is only legal with the tenant's own OpenRouter key.
            // Callers downgrade the policy before building when it's absent.
            input.credentialedProviders.intersection([.openRouter])
        case (.byok, _):
            input.credentialedProviders
        }

        // Profile routes first. BYOK only keeps routes whose provider has a key.
        // Managed keeps all profile routes (table/Hermes cascade covers missing
        // keys) — except under Auto, where the pool stays OpenRouter-only.
        for route in input.profileRoutes {
            if input.mode == .byok || input.policy == .autoSmart,
               !usableProviders.contains(route.provider)
            {
                continue
            }
            append(route)
        }

        for entry in RouterModelCatalog.entries where usableProviders.contains(entry.provider) {
            append(RouterModelRouteDTO(
                provider: entry.provider,
                model: entry.model,
                inputPerMillionUsdMicros: entry.inputPerMillionUsdMicros,
                outputPerMillionUsdMicros: entry.outputPerMillionUsdMicros
            ))
        }

        // Also expand from the client-facing LLM catalog (richer cheap tier list).
        for provider in usableProviders {
            for model in LLMModelCatalog.models(for: provider) {
                append(RouterModelRouteDTO(provider: provider, model: model.id))
            }
        }

        // Tier floor: keep models at or above minTier; if none, keep best available.
        let tiered = candidates.filter { route in
            tier(for: route) >= input.minTier
        }
        if !tiered.isEmpty {
            return tiered
        }
        // Fall back to highest-tier candidates available rather than empty.
        return candidates.sorted { tier(for: $0) > tier(for: $1) }
    }

    static func tier(for route: RouterModelRouteDTO) -> RouterModelTier {
        if let entry = RouterModelCatalog.entry(provider: route.provider, model: route.model) {
            return entry.tier
        }
        return LLMModelCatalog.tier(for: route.provider, model: route.model)
    }

    static func reason(
        policy: LLMRoutingPolicy,
        complexity: RouterComplexity,
        task: RouterTaskType,
        selected: RouterModelRouteDTO,
        deferred: Bool
    ) -> String {
        if deferred {
            return "Routing managed by your Hermes"
        }
        let tier = tier(for: selected)
        switch policy {
        case .locked:
            return "Locked to primary model"
        case .fastCheap:
            return "Fast & Cheap · \(tier.rawValue) tier"
        case .balanced:
            return "Balanced · \(task.rawValue) · \(tier.rawValue)"
        case .maxQuality:
            return "Max Quality · \(tier.rawValue) tier"
        case .autoSmart:
            switch complexity {
            case .low:
                return "Auto · simple \(task.rawValue) → \(tier.rawValue)"
            case .medium:
                return "Auto · moderate \(task.rawValue) → \(tier.rawValue)"
            case .high:
                return "Auto · complex \(task.rawValue) → \(tier.rawValue)"
            }
        }
    }
}
