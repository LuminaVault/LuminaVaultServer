import Foundation

/// HER-161 capability tier requested by a service surface. Drives the
/// routing table — high-stakes chat asks for `.high`, internal kb
/// compilation can fall back to `.low`. Tests rely on full case coverage.
enum LLMCapabilityLevel: String, Codable, CaseIterable {
    case low
    case medium
    case high
}

/// HER-161 routing primitive — a concrete `(provider, model)` pair the
/// transport will try. The `modelID` is rewritten into the request payload
/// before dispatch so the upstream sees the exact model the table picked.
struct ModelRoute: Hashable, ModelIdentifying {
    let provider: ProviderKind
    let modelID: String
}

/// Output of a routing decision. `primary` is the preferred upstream;
/// `fallbacks` is the ordered cascade `RoutedLLMTransport` walks when a
/// provider fails recoverably.
struct RouteDecision: Hashable {
    let primary: ModelRoute
    let fallbacks: [ModelRoute]

    var candidates: [ModelRoute] {
        [primary] + fallbacks
    }
}

/// HER-161 — task-local user threading. The chat path holds a `tenantID`
/// but not a full `User`; middleware/services that *do* have a user push
/// it through this `@TaskLocal` so the router can apply per-user privacy +
/// tier rules without restructuring every service signature.
enum LLMRoutingContext {
    @TaskLocal static var currentUser: User?
}

/// HER-161 — picks an upstream route for a single chat request based on
/// capability tier, requested model hint, and the authenticated user's
/// tier + privacy flags.
protocol ModelRouter: Sendable {
    func pick(forModel model: String?, capability: LLMCapabilityLevel, user: User?) async -> RouteDecision
}

/// HER-161 — default cost-aware router. Picks routes from a static table
/// keyed on `(tier, capability)`, honors `privacy_no_cn_origin`, drops
/// providers without credentials, and always appends a hermesGateway
/// fallback so the chat path never has zero candidates.
struct TableModelRouter: ModelRouter {
    private let registry: ProviderRegistry
    private let hermesDefaultModel: String

    init(registry: ProviderRegistry, hermesDefaultModel: String) {
        self.registry = registry
        self.hermesDefaultModel = hermesDefaultModel
    }

    func pick(forModel _: String?, capability: LLMCapabilityLevel, user: User?) async -> RouteDecision {
        let routes = tableRoutes(capability: capability, tier: effectiveRoutingTier(for: user))
        let privacyFiltered = ModelOriginRegistry.filter(
            routes,
            privacyNoCNOrigin: user?.privacyNoCNOrigin == true,
        )

        var enabled: [ModelRoute] = []
        for route in privacyFiltered where await registry.isEnabled(route.provider) {
            enabled.append(route)
        }

        let selected = enabled.isEmpty ? [hermesRoute] : enabled + [hermesRoute]
        return RouteDecision(primary: selected[0], fallbacks: Array(selected.dropFirst()))
    }

    private var hermesRoute: ModelRoute {
        ModelRoute(provider: .hermesGateway, modelID: hermesDefaultModel)
    }

    private func effectiveRoutingTier(for user: User?) -> RoutingTier {
        guard let user else { return .free }
        let effective = EntitlementChecker.effectiveTier(tier: user.tierEnum, override: user.tierOverrideEnum)
        switch effective {
        case .pro, .ultimate:
            return .pro
        case .trial, .lapsed, .archived:
            return .free
        }
    }

    private func tableRoutes(capability: LLMCapabilityLevel, tier: RoutingTier) -> [ModelRoute] {
        switch (tier, capability) {
        case (.pro, .high):
            [
                ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"),
                ModelRoute(provider: .anthropic, modelID: "claude-opus-4.7"),
                ModelRoute(provider: .openai, modelID: "gpt-5"),
            ]
        case (.pro, .medium), (.pro, .low):
            [
                ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4.6"),
                ModelRoute(provider: .gemini, modelID: "gemini-2.5-pro"),
            ]
        case (.free, .high):
            [
                ModelRoute(provider: .together, modelID: "deepseek-v3.2"),
                ModelRoute(provider: .groq, modelID: "kimi-k2"),
            ]
        case (.free, .medium), (.free, .low):
            [
                ModelRoute(provider: .gemini, modelID: "gemini-flash"),
                ModelRoute(provider: .together, modelID: "deepseek"),
            ]
        }
    }

    private enum RoutingTier {
        case free
        case pro
    }
}

/// HER-165 single-gateway router. Routes every call to `hermesGateway`
/// regardless of capability tier. Kept as a deployment fallback for
/// environments that don't configure external providers.
struct SingleGatewayModelRouter: ModelRouter {
    private let hermesDefaultModel: String

    init(hermesDefaultModel: String = "hermes-3") {
        self.hermesDefaultModel = hermesDefaultModel
    }

    func pick(forModel _: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
        RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: hermesDefaultModel),
            fallbacks: [],
        )
    }
}

/// HER-200 model-hint router. Routes `gemini*` model strings to the Gemini
/// provider and everything else to the Hermes gateway. Useful when a chat
/// caller wants explicit provider control via the `model` field rather
/// than capability-tier routing.
struct RoutingModelRouter: ModelRouter {
    private let hermesDefaultModel: String
    private let fallbacks: [ProviderKind]

    init(hermesDefaultModel: String = "hermes-3", fallbacks: [ProviderKind] = []) {
        self.hermesDefaultModel = hermesDefaultModel
        self.fallbacks = fallbacks
    }

    func pick(forModel model: String?, capability _: LLMCapabilityLevel, user _: User?) async -> RouteDecision {
        let fallbackRoutes = fallbacks.map { ModelRoute(provider: $0, modelID: hermesDefaultModel) }
        guard let model, !model.isEmpty else {
            return RouteDecision(
                primary: ModelRoute(provider: .hermesGateway, modelID: hermesDefaultModel),
                fallbacks: fallbackRoutes,
            )
        }
        let lower = model.lowercased()
        if lower.hasPrefix("gemini") {
            return RouteDecision(
                primary: ModelRoute(provider: .gemini, modelID: model),
                fallbacks: [ModelRoute(provider: .hermesGateway, modelID: hermesDefaultModel)] + fallbackRoutes,
            )
        }
        return RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: model),
            fallbacks: fallbackRoutes,
        )
    }
}
