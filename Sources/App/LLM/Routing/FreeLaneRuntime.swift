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
