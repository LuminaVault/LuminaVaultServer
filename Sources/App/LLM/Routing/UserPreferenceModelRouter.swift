import Foundation
import Logging

/// HER-252 — `ModelRouter` that consults a per-user preference (primary
/// route + ordered fallback chain) before falling through to the
/// underlying static `TableModelRouter`. The static table is always
/// stitched on as the last-resort cascade so the chat path never gets
/// an empty candidate list.
///
/// Decision shape per request:
///   primary  = user.primary
///   fallback = user.fallbackChain + table.primary + table.fallbacks
///
/// When no user row exists (or the user pref provider is `.hermesGateway`
/// — a sentinel for "use default routing"), the router delegates
/// entirely to the table.
struct UserPreferenceModelRouter: ModelRouter {
    let preferences: UserLLMPreferenceRepository
    let fallback: any ModelRouter
    let logger: Logger

    func pick(
        forModel model: String?,
        capability: LLMCapabilityLevel,
        user: User?
    ) async -> RouteDecision {
        let tableDecision = await fallback.pick(forModel: model, capability: capability, user: user)
        guard
            let user,
            let tenantID = try? user.requireID()
        else {
            return tableDecision
        }
        let pref: UserLLMPreferenceRepository.Snapshot?
        do {
            pref = try await preferences.get(tenantID: tenantID)
        } catch {
            logger.error("user llm preference lookup failed: \(error)")
            return tableDecision
        }
        guard let pref else {
            return tableDecision
        }
        // HER-300 — `managed` users explicitly opted out of BYOK routing:
        // delegate entirely to the static table (which already cascades
        // through to the shared Hermes gateway), so we don't honour a
        // primary/fallback chain that lacks user credentials. The pref
        // row's `primaryModel` is preserved for the iOS UI but doesn't
        // steer routing — Hermes' own default model wins for managed.
        if pref.mode == .managed {
            return tableDecision
        }

        let primary = ModelRoute(provider: pref.primaryProvider, modelID: pref.primaryModel)
        let chain = pref.fallbackChain.map { ModelRoute(provider: $0.provider, modelID: $0.model) }

        /// Provider allow/block lists constrain every candidate, including the
        /// stitched-on table defaults. Block-list always wins; a non-empty
        /// allow-list means "only these providers".
        func isAllowed(_ provider: ProviderKind) -> Bool {
            if pref.blockedProviders.contains(provider) {
                return false
            }
            if !pref.allowedProviders.isEmpty, !pref.allowedProviders.contains(provider) {
                return false
            }
            return true
        }

        // Primary first, then user chain, then the static table cascade so a
        // user whose entire chain lacks creds still gets a route. Dedupe by
        // provider+model and drop anything the lists exclude.
        var seen = Set<ModelRoute>()
        var allowed: [ModelRoute] = []
        for route in [primary] + chain + tableDecision.candidates {
            guard isAllowed(route.provider) else { continue }
            guard !seen.contains(route) else { continue }
            seen.insert(route)
            allowed.append(route)
        }

        guard let newPrimary = allowed.first else {
            // Lists filtered everything out — never hand back an empty
            // candidate list; fall through to the unfiltered table cascade.
            logger.warning("llm allow/block lists filtered out all routes; using table cascade")
            return tableDecision
        }
        return RouteDecision(primary: newPrimary, fallbacks: Array(allowed.dropFirst()))
    }
}
