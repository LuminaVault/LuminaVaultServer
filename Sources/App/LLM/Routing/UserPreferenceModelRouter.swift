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
        user: User?,
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

        let primary = ModelRoute(provider: pref.primaryProvider, modelID: pref.primaryModel)
        let chain = pref.fallbackChain.map { ModelRoute(provider: $0.provider, modelID: $0.model) }
        // Stitch the static table's candidates on as the final cascade so
        // even a user whose entire chain has no available creds still
        // gets a route. Dedupe trivially by provider+model.
        var seen = Set<ModelRoute>()
        var allFallbacks: [ModelRoute] = []
        for route in chain + tableDecision.candidates {
            if route == primary { continue }
            guard !seen.contains(route) else { continue }
            seen.insert(route)
            allFallbacks.append(route)
        }
        return RouteDecision(primary: primary, fallbacks: allFallbacks)
    }
}
