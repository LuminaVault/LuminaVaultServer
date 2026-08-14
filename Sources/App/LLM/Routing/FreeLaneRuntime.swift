import Foundation

/// Everything the router needs to serve the free lane: the gate that meters it
/// and the two model ids, both configurable so a slug change is a redeploy
/// rather than a release.
struct FreeLaneRuntime: Sendable {
    let gate: FreeLaneGate
    let openRouterModel: String
    let nvidiaModel: String

    init(
        gate: FreeLaneGate,
        openRouterModel: String = FreeLaneCatalog.defaultOpenRouterModel,
        nvidiaModel: String = FreeLaneCatalog.defaultNvidiaModel
    ) {
        self.gate = gate
        self.openRouterModel = openRouterModel
        self.nvidiaModel = nvidiaModel
    }

    func routes(preferring leg: FreeLaneCatalog.Leg? = nil) -> [FreeLaneCatalog.Route] {
        FreeLaneCatalog.routes(
            openRouterModel: openRouterModel,
            nvidiaModel: nvidiaModel,
            preferring: leg
        )
    }
}
