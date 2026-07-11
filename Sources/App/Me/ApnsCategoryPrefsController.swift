import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension APNSCategoryPrefsResponse: @retroactive ResponseEncodable {}

/// HER-179 — `GET/PUT /v1/me/apns-categories`. Per-tenant opt-out for
/// the three APNS notification categories (`chat`, `nudge`, `digest`).
/// Absence of a row defaults all categories to enabled.
struct ApnsCategoryPrefsController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/apns-categories", use: get)
        router.put("/apns-categories", use: put)
    }

    @Sendable
    func get(_: Request, ctx: AppRequestContext) async throws -> APNSCategoryPrefsResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        if let row = try await ApnsCategoryPrefs.find(tenantID, on: fluent.db()) {
            return APNSCategoryPrefsResponse(
                chatEnabled: row.chatEnabled,
                nudgeEnabled: row.nudgeEnabled,
                digestEnabled: row.digestEnabled
            )
        }
        return APNSCategoryPrefsResponse(chatEnabled: true, nudgeEnabled: true, digestEnabled: true)
    }

    @Sendable
    func put(_ req: Request, ctx: AppRequestContext) async throws -> APNSCategoryPrefsResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: APNSCategoryPrefsPutRequest.self, context: ctx)

        let db = fluent.db()
        let row = try await ApnsCategoryPrefs.find(tenantID, on: db)
            ?? ApnsCategoryPrefs(tenantID: tenantID)
        if let chat = body.chatEnabled {
            row.chatEnabled = chat
        }
        if let nudge = body.nudgeEnabled {
            row.nudgeEnabled = nudge
        }
        if let digest = body.digestEnabled {
            row.digestEnabled = digest
        }
        try await row.save(on: db)

        return APNSCategoryPrefsResponse(
            chatEnabled: row.chatEnabled,
            nudgeEnabled: row.nudgeEnabled,
            digestEnabled: row.digestEnabled
        )
    }
}
