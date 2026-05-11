import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent

struct DeviceRegistrationRequest: Codable {
    let token: String
    let platform: String
}

struct DeviceRegistrationResponse: Codable, ResponseEncodable {
    let id: UUID
    let token: String
    let platform: String
}

struct DeviceController {
    let fluent: Fluent

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: register)
        router.delete("/:token", use: unregister)
    }

    @Sendable
    func register(_ req: Request, ctx: AppRequestContext) async throws -> DeviceRegistrationResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: DeviceRegistrationRequest.self, context: ctx)
        guard !body.token.isEmpty else { throw HTTPError(.badRequest, message: "token required") }
        let platform = body.platform.lowercased()
        guard ["ios", "android"].contains(platform) else {
            throw HTTPError(.badRequest, message: "platform must be ios or android")
        }
        let tenantID = try user.requireID()

        let db = fluent.db()
        if let existing = try await DeviceToken.query(on: db, tenantID: tenantID)
            .filter(\.$token == body.token)
            .first()
        {
            existing.platform = platform
            existing.lastSeenAt = Date()
            try await existing.save(on: db)
            return try DeviceRegistrationResponse(
                id: existing.requireID(),
                token: existing.token,
                platform: existing.platform,
            )
        }

        let row = DeviceToken(tenantID: tenantID, token: body.token, platform: platform)
        try await row.save(on: db)
        return try DeviceRegistrationResponse(
            id: row.requireID(),
            token: row.token,
            platform: row.platform,
        )
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
