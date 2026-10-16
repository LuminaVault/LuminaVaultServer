import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension DeviceRegistrationResponse: @retroactive ResponseEncodable {}

struct DeviceController {
    let fluent: Fluent
    /// `apns.bundleId`. A device's own bundle id is kept only when it is this
    /// or a variant of it (`APNSNotificationService.isAllowedBundleID`).
    var apnsBundleID: String = ""
    var logger = Logger(label: "lv.devices")

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: register)
        router.delete("/:token", use: unregister)
    }

    @Sendable
    func register(_ req: Request, ctx: AppRequestContext) async throws -> DeviceRegistrationResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: DeviceRegistrationRequest.self, context: ctx)
        guard !body.token.isEmpty else { throw HTTPError(.badRequest, message: "token required") }
        let platform = body.platform.rawValue
        let tenantID = try user.requireID()
        let bundleID = allowedBundleID(body.bundleId)

        let db = fluent.db()
        if let existing = try await DeviceToken.query(on: db, tenantID: tenantID)
            .filter(\.$token == body.token)
            .first()
        {
            existing.platform = platform
            existing.lastSeenAt = Date()
            // An older client sends no bundle id; keep what a newer one stored.
            if body.bundleId != nil {
                existing.bundleID = bundleID
            }
            try await existing.save(on: db)
            return try DeviceRegistrationResponse(
                id: existing.requireID(),
                token: existing.token,
                platform: existing.platform
            )
        }

        let row = DeviceToken(tenantID: tenantID, token: body.token, platform: platform, bundleID: bundleID)
        try await row.save(on: db)
        return try DeviceRegistrationResponse(
            id: row.requireID(),
            token: row.token,
            platform: row.platform
        )
    }

    /// The requested bundle id when the server may push to it, else nil (the
    /// push then uses the configured id). A foreign id is dropped, not refused:
    /// registration must still succeed.
    func allowedBundleID(_ requested: String?) -> String? {
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
            return nil
        }
        guard APNSNotificationService.isAllowedBundleID(requested, configured: apnsBundleID) else {
            logger.debug("device bundle id \(requested) is not \(apnsBundleID) or a variant of it; using the default topic")
            return nil
        }
        return requested
    }

    @Sendable
    func unregister(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        guard let token = ctx.parameters.get("token") else {
            throw HTTPError(.badRequest, message: "missing token")
        }
        let tenantID = try user.requireID()
        try await DeviceToken.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$token == token)
            .delete()
        return Response(status: .noContent)
    }
}
