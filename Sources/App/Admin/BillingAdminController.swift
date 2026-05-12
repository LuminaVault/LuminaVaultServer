import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent

struct SetTierOverrideRequest: Codable {
    let tierOverride: String
}

struct UserBillingSummary: Codable, ResponseEncodable {
    let id: UUID
    let tier: String
    let tierExpiresAt: Date?
    let tierOverride: String
    let revenuecatUserID: String?
}

struct BillingAdminController {
    let fluent: Fluent

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.put("/users/:userID/tier-override", use: setTierOverride)
    }

    @Sendable
    func setTierOverride(_ req: Request, ctx: AppRequestContext) async throws -> UserBillingSummary {
        let userID = try Self.parseUserID(ctx)
        let body = try await req.decode(as: SetTierOverrideRequest.self, context: ctx)
        guard let override = TierOverride(rawValue: body.tierOverride) else {
            throw HTTPError(.badRequest, message: "tierOverride must be one of: none, pro, ultimate")
        }
        guard let user = try await User.find(userID, on: fluent.db()) else {
            throw HTTPError(.notFound, message: "user not found")
        }
        user.tierOverride = override.rawValue
        try await user.save(on: fluent.db())
        return try UserBillingSummary(user)
    }

    private static func parseUserID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("userID"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid userID")
        }
        return id
    }
}

extension UserBillingSummary {
    init(_ user: User) throws {
        id = try user.requireID()
        tier = user.tier
        tierExpiresAt = user.tierExpiresAt
        tierOverride = user.tierOverride
        revenuecatUserID = user.revenuecatUserID
    }
}
