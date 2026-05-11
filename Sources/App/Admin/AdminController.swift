import Foundation
import Hummingbird

extension HermesProfileReconcileSummary: ResponseEncodable {}
extension HermesProfileReapSummary: ResponseEncodable {}
extension HermesProfileHealth: ResponseEncodable {}

struct AdminController {
    let reconciler: HermesProfileReconciler

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/health", use: health)
        router.post("/reconcile", use: reconcile)
        router.post("/reap-orphans", use: reapOrphans)
    }

    @Sendable
    func health(_: Request, ctx _: AppRequestContext) async throws -> HermesProfileHealth {
        try await reconciler.health()
    }

    @Sendable
    func reconcile(_: Request, ctx _: AppRequestContext) async throws -> HermesProfileReconcileSummary {
        try await reconciler.reconcile()
    }

    @Sendable
    func reapOrphans(_: Request, ctx _: AppRequestContext) async throws -> HermesProfileReapSummary {
        try await reconciler.reapOrphans()
    }
}
