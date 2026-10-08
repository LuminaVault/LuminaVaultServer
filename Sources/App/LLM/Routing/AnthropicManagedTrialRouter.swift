import Foundation
import LuminaVaultShared

/// Puts the Anthropic trial route in front of the decision another router
/// made, so `RoutedLLMTransport` walks Anthropic → the original pick → its
/// fallbacks. Any failure on the Anthropic leg (non-2xx, refusal, empty
/// output) is recoverable, so hitting the trial's spend cap silently hands
/// traffic back to the chain that served it before.
///
/// Only platform-paid traffic is touched. Everything else returns the inner
/// decision unchanged:
/// - BYOK (the tenant pays their own provider; the trial key must never
///   stand in for theirs),
/// - BYO Hermes (the tenant chose their own box; see `deferredToHermes`),
/// - ensembles (`ParallelExecutor` dispatches `cerberus.routes`, not
///   `candidates`),
/// - decisions the transport will refuse before dispatch anyway,
/// - free-lane decisions when `ANTHROPIC_SCOPE=paid`.
struct AnthropicManagedTrialRouter: ModelRouter {
    let inner: any ModelRouter
    let config: AnthropicManagedTrialConfig

    func pick(forModel model: String?, capability: LLMCapabilityLevel, user: User?) async -> RouteDecision {
        let decision = await inner.pick(forModel: model, capability: capability, user: user)
        return Self.apply(
            config,
            to: decision,
            contextCredentialMode: LLMRoutingContext.credentialMode,
            isUserHermesOverride: LLMRoutingContext.currentResolution?.isUserOverride == true
        )
    }

    /// Pure decision rewrite, separated from the task-locals for tests.
    static func apply(
        _ config: AnthropicManagedTrialConfig,
        to decision: RouteDecision,
        contextCredentialMode: LLMBrainMode?,
        isUserHermesOverride: Bool
    ) -> RouteDecision {
        // Same precedence `RoutedLLMTransport` uses when it binds the mode for
        // the adapters, so "managed" here means what the adapter will see.
        let mode = decision.credentialMode ?? decision.cerberus?.mode ?? contextCredentialMode
        guard mode != .byok, !isUserHermesOverride else { return decision }
        if let cerberus = decision.cerberus {
            if cerberus.deferredToHermes || cerberus.strategy == .ensemble {
                return decision
            }
            if cerberus.preflightError() != nil {
                return decision
            }
            if cerberus.isFreeLane, config.scope == .paid {
                return decision
            }
        }
        let trial = config.route
        if decision.primary == trial {
            return decision
        }
        return RouteDecision(
            primary: trial,
            fallbacks: decision.candidates.filter { $0 != trial },
            cerberus: decision.cerberus,
            credentialMode: decision.credentialMode,
            managedTrialPrepended: true
        )
    }
}

extension RouteDecision {
    /// The decision as it was before the trial route was put in front of it.
    ///
    /// The managed chat stream rides the Hermes gateway (and its agentic loop)
    /// rather than `RoutedLLMTransport`, and only knows how to dispatch a
    /// gateway / OpenRouter primary. Without this, the trial would silently
    /// demote every managed Auto pick there to the gateway's default model.
    func removingManagedTrialRoute() -> RouteDecision {
        guard managedTrialPrepended, let original = fallbacks.first else { return self }
        return RouteDecision(
            primary: original,
            fallbacks: Array(fallbacks.dropFirst()),
            cerberus: cerberus,
            credentialMode: credentialMode
        )
    }
}
