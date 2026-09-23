import Foundation

/// Everything the router needs to serve the free lane: the gate that meters it
/// and the three model ids, all configurable so a slug change is a redeploy
/// rather than a release.
struct FreeLaneRuntime: Sendable {
    let gate: FreeLaneGate
    let openRouterModel: String
    /// Second hop on the same OpenRouter key and the same gate counter.
    let openRouterSecondaryModel: String
    let nvidiaModel: String

    init(
        gate: FreeLaneGate,
        openRouterModel: String = FreeLaneCatalog.defaultOpenRouterModel,
        openRouterSecondaryModel: String = FreeLaneCatalog.defaultOpenRouterSecondaryModel,
        nvidiaModel: String = FreeLaneCatalog.defaultNvidiaModel
    ) {
        self.gate = gate
        self.openRouterModel = openRouterModel
        self.openRouterSecondaryModel = openRouterSecondaryModel
        self.nvidiaModel = nvidiaModel
    }

    func routes(preferring leg: FreeLaneCatalog.Leg? = nil) -> [FreeLaneCatalog.Route] {
        FreeLaneCatalog.routes(
            openRouterModel: openRouterModel,
            openRouterSecondaryModel: openRouterSecondaryModel,
            nvidiaModel: nvidiaModel,
            preferring: leg
        )
    }
}

extension FreeLaneRuntime {
    /// What to say at boot when the lane is switched on but none of its legs
    /// has a platform key, or nil when there is nothing to say.
    ///
    /// Such a lane still claims every request that falls to it and answers each
    /// one with `free_lane_unavailable`. That is correct per request, but it is
    /// a deploy mistake, and the time to hear about it is startup, not the
    /// first user's 503.
    static func startupWarning(enabled: Bool, openRouterEnabled: Bool, nvidiaEnabled: Bool) -> String? {
        guard enabled, !openRouterEnabled, !nvidiaEnabled else { return nil }
        return "freelane.enabled is true but neither the OpenRouter nor the NVIDIA platform key loaded; "
            + "every free-lane request will answer 503 free_lane_unavailable"
    }
}
