import Foundation

/// HER-165 — output of a routing decision. `primary` is the preferred
/// upstream; `fallbacks` is the ordered list `RoutedLLMTransport` walks
/// when `primary` throws a recoverable error.
///
/// `fallbacks` should be ordered by cost-then-quality so a brief outage
/// upgrades the user to a slightly more expensive route rather than
/// downgrading to a worse model.
struct ModelDecision: Hashable {
    let primary: ProviderKind
    let fallbacks: [ProviderKind]

    /// Convenience for adapters / logging — the candidate list in order
    /// (primary first).
    var candidates: [ProviderKind] {
        [primary] + fallbacks
    }
}

/// HER-165 — picks an upstream for a single chat request. The default
/// impl is intentionally trivial: it always returns `hermesGateway` with
/// no fallbacks, preserving today's single-gateway behavior while making
/// the call sites routing-aware.
///
/// HER-161 will land a cost-aware impl that respects:
/// - the user's `privacy_no_cn_origin` flag (HER-176, already in `User`)
/// - the requested model name in the inbound payload
/// - the user's tier (Free / Trial users only see free providers)
/// - per-provider live availability snapshot
protocol ModelRouter: Sendable {
    func pick(forModel model: String?, user: User?) async -> ModelDecision
}

/// Default scaffold router: every request goes to `hermesGateway`.
/// HER-165 ships this; HER-161 swaps in the real impl.
struct SingleGatewayModelRouter: ModelRouter {
    func pick(forModel _: String?, user _: User?) async -> ModelDecision {
        ModelDecision(primary: .hermesGateway, fallbacks: [])
    }
}

/// HER-200 — model-based router that routes Gemini model hints to the
/// Gemini provider and everything else to the Hermes gateway. Supports
/// user-facing model names like `gemini-2.5-pro`, `gemini-2.5-flash`,
/// or any custom model — the adapter-level translation handles the rest.
struct RoutingModelRouter: ModelRouter {
    private let fallbacks: [ProviderKind]

    init(fallbacks: [ProviderKind] = []) {
        self.fallbacks = fallbacks
    }

    func pick(forModel model: String?, user _: User?) async -> ModelDecision {
        guard let model, !model.isEmpty else {
            return ModelDecision(primary: .hermesGateway, fallbacks: fallbacks)
        }
        let lower = model.lowercased()
        if lower.hasPrefix("gemini") {
            return ModelDecision(primary: .gemini, fallbacks: [.hermesGateway] + fallbacks)
        }
        return ModelDecision(primary: .hermesGateway, fallbacks: fallbacks)
    }
}
