import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

extension LastKnownLocationResponse: @retroactive ResponseEncodable {}

/// Muse Chat stage C — the location fix kept for offline weather jobs.
///
/// - `GET    /v1/me/location` — what is stored (`cached: false` when nothing).
/// - `DELETE /v1/me/location` — forget it (204). The next live device read
///   stores a new one while Location access is on; turning Location access
///   off clears it too (`AppleConsentController.purgeDomain`).
struct LastKnownLocationController {
    let fluent: Fluent

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("location", use: get)
        router.delete("location", use: forget)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> LastKnownLocationResponse {
        let tenantID = try ctx.requireTenantID()
        guard let fix = try await store().load(tenantID: tenantID) else {
            return LastKnownLocationResponse(cached: false)
        }
        return LastKnownLocationResponse(
            cached: true,
            place: fix.place,
            latitude: fix.latitude,
            longitude: fix.longitude,
            capturedAt: fix.capturedAt
        )
    }

    @Sendable
    func forget(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        try await store().clear(tenantID: tenantID)
        return Response(status: .noContent)
    }

    private func store() throws -> LastKnownLocationStore {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }
        return LastKnownLocationStore(sql: sql)
    }
}
