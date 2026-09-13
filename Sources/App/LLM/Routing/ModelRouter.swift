import Foundation
import LuminaVaultShared

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
    let cerberus: CerberusDecisionMetadata?
    /// Who pays for this request. Adapters use it to decide whether the
    /// deployment key is legal (`.managed`) or whether a missing tenant
    /// credential must fail closed (`.byok`).
    ///
    /// `CerberusDecisionMetadata.mode` already carries this, but that metadata
    /// is absent whenever `CERBERUS_EXECUTION_MODE != "active"`, which left
    /// `credentialMode` nil on every chat call under the legacy router and
    /// silently degraded the fail-closed guard back to fail-open. Routers that
    /// know the mode publish it here regardless of which one is active.
    ///
    /// `nil` still means "nobody declared an intent" — internal and cron work
    /// with no user attached — and keeps managed semantics.
    let credentialMode: LLMBrainMode?

    init(
        primary: ModelRoute,
        fallbacks: [ModelRoute],
        cerberus: CerberusDecisionMetadata? = nil,
        credentialMode: LLMBrainMode? = nil
    ) {
        self.primary = primary
        self.fallbacks = fallbacks
        self.cerberus = cerberus
        self.credentialMode = credentialMode
    }

    var candidates: [ModelRoute] {
        [primary] + fallbacks
    }
}

/// HER-161 — task-local user threading. The chat path holds a `tenantID`
/// but not a full `User`; middleware/services that *do* have a user push
/// it through this `@TaskLocal` so the router can apply per-user privacy +
/// tier rules without restructuring every service signature.
///
/// HER-223 — same trick for the BYO Hermes `Resolution`.
/// `HermesResolutionMiddleware` pushes the resolved override (if any) into
/// `currentResolution`; `HermesGatewayAdapter` reads it inside
/// `chatCompletionsWithMetadata` and dispatches against the user's gateway
/// + Authorization header when `isUserOverride == true`. Avoids threading
/// `Resolution` through every consumer service signature.
enum LLMRoutingContext {
    /// HER-330 — every routing value lives in ONE task-local.
    ///
    /// These used to be a dozen separate `@TaskLocal`s, and `streamReply`
    /// bound ten of them nested inside an unstructured `Task`. That
    /// segfaulted the server on every chat message:
    /// `swift_task_localValuePush` allocates on the async stack, but SIL
    /// does not model that allocation, so the surrounding
    /// `alloc_stack`/`dealloc_stack` push twice and pop once
    /// (swiftlang/swift#67559). Exposure scales with how many pushes stack
    /// up in one async frame — four bindings in `LLMController` never
    /// crashed, ten here always did.
    ///
    /// One struct means one push no matter how many values a caller binds.
    /// The accessors below keep the original names, so the ~50 read sites
    /// are unchanged.
    struct Values: Sendable {
        var currentUser: User?
        var currentResolution: HermesEndpointResolver.Resolution?
        var cerberusScope: CerberusRequestScope?
        var cerberusPrompt: String?
        var parallelStrategy: ParallelStrategyDTO?
        var parallelRequest: ParallelExecutionRequestDTO?
        var forcedRoute: RouterModelRouteDTO?
        var routeOutcomeSink: (@Sendable (ModelProvenanceDTO) -> Void)?
        var analyticsVaultID: UUID?
        var billingTenantID: UUID?
        var credentialMode: LLMBrainMode?
        var conversationMessageID: UUID?
        /// Streaming sinks live here too, so a streaming caller binds
        /// everything in the same single push. `CerberusStreamContext` and
        /// `FailoverNoticeContext` read them back under their own names.
        var cerberusSink: (@Sendable (QueryStreamEvent) -> Void)?
        var failoverSink: (@Sendable (ProviderFailoverNotice) -> Void)?

        init() {}
    }

    @TaskLocal static var values = Values()

    /// Binds any subset of the routing values in a single task-local push.
    /// Values not touched by `mutate` are inherited from the enclosing
    /// scope, so nesting behaves exactly as separate `@TaskLocal`s did.
    ///
    /// `isolation` is forwarded so `operation` runs in the caller's isolation
    /// rather than being sent across a boundary — without it, call sites that
    /// pass a non-Sendable async closure fail to compile.
    static func withValues<Result>(
        _ mutate: (inout Values) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        var next = values
        mutate(&next)
        return try await $values.withValue(next, operation: operation, isolation: isolation)
    }

    /// Synchronous counterpart, mirroring `TaskLocal.withValue`'s own sync
    /// overload. `RoutedLLMTransport` binds the credential mode around a
    /// non-async `chatStream` call and must not be forced into an `await`.
    static func withValues<Result>(
        _ mutate: (inout Values) -> Void,
        operation: () throws -> Result
    ) rethrows -> Result {
        var next = values
        mutate(&next)
        return try $values.withValue(next, operation: operation)
    }

    static var currentUser: User? { values.currentUser }
    static var currentResolution: HermesEndpointResolver.Resolution? { values.currentResolution }
    static var cerberusScope: CerberusRequestScope? { values.cerberusScope }
    static var cerberusPrompt: String? { values.cerberusPrompt }
    /// Explicit per-turn multi-model override. `nil` preserves the active
    /// Router profile's normal sequential/ensemble behavior.
    static var parallelStrategy: ParallelStrategyDTO? { values.parallelStrategy }
    static var parallelRequest: ParallelExecutionRequestDTO? { values.parallelRequest }
    /// Exact per-conversation route selected by “Ask another model”. Unlike
    /// ordinary routing this has no silent fallback.
    static var forcedRoute: RouterModelRouteDTO? { values.forcedRoute }
    static var routeOutcomeSink: (@Sendable (ModelProvenanceDTO) -> Void)? { values.routeOutcomeSink }
    /// Validated vault attribution for analytics. Callers that do not set it
    /// intentionally fall back to the actor's personal vault.
    static var analyticsVaultID: UUID? { values.analyticsVaultID }
    /// Account charged for AI usage. Team vaults bind this to their billing
    /// sponsor while preserving `currentUser` for personal routing/privacy.
    static var billingTenantID: UUID? { values.billingTenantID }
    /// Selects platform-managed versus user-owned provider credentials for
    /// the current routed call. Managed mode must never silently spend a
    /// user's BYOK balance, and BYOK mode must never fall back to the pool.
    static var credentialMode: LLMBrainMode? { values.credentialMode }
    /// The assistant turn this routed call produced, when there is one.
    ///
    /// Lets `agent_turn_traces` attach a trace to the message a user is
    /// looking at. Nil for routed calls that are not conversation turns —
    /// skill runs, workflow nodes, one-shot classifiers — whose traces are
    /// still recorded, just unattached.
    static var conversationMessageID: UUID? { values.conversationMessageID }
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
            privacyNoCNOrigin: user?.privacyNoCNOrigin == true
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
        case .free, .trial, .lapsed, .archived:
            return .free
        }
    }

    private func tableRoutes(capability: LLMCapabilityLevel, tier: RoutingTier) -> [ModelRoute] {
        switch (tier, capability) {
        case (.pro, .high):
            [
                ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4-6"),
                ModelRoute(provider: .anthropic, modelID: "claude-opus-4-7"),
                ModelRoute(provider: .openai, modelID: "gpt-5"),
            ]
        case (.pro, .medium), (.pro, .low):
            [
                ModelRoute(provider: .anthropic, modelID: "claude-sonnet-4-6"),
                ModelRoute(provider: .gemini, modelID: "gemini-2.5-pro"),
            ]
        // Non-entitled users get the free lane at every capability level.
        // The rows that used to sit here named Together/Groq/Gemini models
        // whose keys are unset in every deployment, so they were filtered out
        // and collapsed to `hermesRoute` — i.e. the "free" tier was silently
        // billing the gateway's key. Both legs below cost $0.
        //
        // This path has no `FreeLaneGate` metering: there is no
        // `CerberusDecisionMetadata` here to carry an exhaustion error through,
        // and this router is only reachable as the documented
        // `CERBERUS_EXECUTION_MODE` rollback. The structural cost fix still
        // holds because neither leg is billable.
        case (.free, .high), (.free, .medium), (.free, .low):
            FreeLaneCatalog.routes().compactMap { route in
                ProviderKind(shared: route.provider).map {
                    ModelRoute(provider: $0, modelID: route.model)
                }
            }
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
            fallbacks: []
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
                fallbacks: fallbackRoutes
            )
        }
        let lower = model.lowercased()
        if lower.hasPrefix("gemini") {
            return RouteDecision(
                primary: ModelRoute(provider: .gemini, modelID: model),
                fallbacks: [ModelRoute(provider: .hermesGateway, modelID: hermesDefaultModel)] + fallbackRoutes
            )
        }
        return RouteDecision(
            primary: ModelRoute(provider: .hermesGateway, modelID: model),
            fallbacks: fallbackRoutes
        )
    }
}
