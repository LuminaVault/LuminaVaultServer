import FluentKit
import Foundation
import Hummingbird
import LuminaVaultShared

extension MarketplaceListResponse: @retroactive ResponseEncodable {}
extension MarketplacePluginDTO: @retroactive ResponseEncodable {}
extension MarketplaceReviewsResponse: @retroactive ResponseEncodable {}
extension MarketplaceReviewDTO: @retroactive ResponseEncodable {}
extension MarketplacePublisherDTO: @retroactive ResponseEncodable {}
extension MarketplacePublishersResponse: @retroactive ResponseEncodable {}
extension MarketplaceVersionDTO: @retroactive ResponseEncodable {}
extension MarketplaceSubmissionDTO: @retroactive ResponseEncodable {}
extension MarketplaceSubmissionsResponse: ResponseEncodable {}
extension PluginToolRunResponse: @retroactive ResponseEncodable {}
extension MarketplaceArtifactUploadResponse: @retroactive ResponseEncodable {}

struct MarketplaceController {
    let marketplace: MarketplaceService
    let plugins: PluginService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("plugins", use: list)
        router.get("plugins/:slug", use: detail)
        router.get("plugins/:slug/reviews", use: reviews)
        router.put("plugins/:slug/rating", use: rate)
        router.post("plugins/:slug/install", use: install)
        router.post("plugins/:slug/upgrade", use: upgrade)
        router.post("plugins/:slug/tools/:toolName/run", use: runTool)

        router.post("publisher/apply", use: applyPublisher)
        router.get("publisher", use: publisher)
        router.post("publisher/plugins", use: createListing)
        router.post("publisher/plugins/:slug/versions", use: createVersion)
        router.post("publisher/plugins/:slug/artifacts", use: uploadArtifact)
        router.post("publisher/plugins/:slug/versions/:versionID/submit", use: submit)
        router.get("publisher/submissions", use: publisherSubmissions)

        router.get("admin/submissions", use: adminSubmissions)
        router.get("admin/publishers", use: adminPublishers)
        router.post("admin/submissions/:submissionID/decision", use: moderate)
        router.post("admin/publishers/:publisherID/decision", use: moderatePublisher)
        router.post("admin/versions/:versionID/revoke", use: revokeVersion)
    }

    @Sendable private func list(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceListResponse {
        _ = try ctx.requireTenantID()
        let category = req.uri.queryParameters.get("category").flatMap(PluginCategory.init(rawValue:))
        let featured = req.uri.queryParameters.get("featured").flatMap(Self.bool)
        let limit = min(50, max(1, Int(req.uri.queryParameters.get("limit") ?? "24") ?? 24))
        return try await marketplace.list(
            query: req.uri.queryParameters.get("query"), category: category, featured: featured,
            cursor: req.uri.queryParameters.get("cursor"), limit: limit
        )
    }

    @Sendable private func detail(_: Request, ctx: AppRequestContext) async throws -> MarketplacePluginDTO {
        _ = try ctx.requireTenantID()
        return try await marketplace.detail(slug: Self.path(ctx, "slug"))
    }

    @Sendable private func reviews(_: Request, ctx: AppRequestContext) async throws -> MarketplaceReviewsResponse {
        _ = try ctx.requireTenantID()
        return try await marketplace.reviews(slug: Self.path(ctx, "slug"))
    }

    @Sendable private func rate(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceReviewDTO {
        let body = try await req.decode(as: MarketplaceRatingRequest.self, context: ctx)
        return try await marketplace.rate(slug: Self.path(ctx, "slug"), userID: ctx.requireTenantID(), request: body)
    }

    @Sendable private func install(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let body = try await req.decode(as: MarketplaceInstallRequest.self, context: ctx)
        return try await plugins.installMarketplace(
            tenantID: ctx.requireTenantID(), slug: Self.path(ctx, "slug"),
            versionID: body.versionId, grantedPermissions: body.grantedPermissions, config: body.config
        )
    }

    @Sendable private func upgrade(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let body = try await req.decode(as: MarketplaceUpgradeRequest.self, context: ctx)
        return try await plugins.upgradeMarketplace(
            tenantID: ctx.requireTenantID(), slug: Self.path(ctx, "slug"), request: body
        )
    }

    @Sendable private func runTool(_ req: Request, ctx: AppRequestContext) async throws -> PluginToolRunResponse {
        let body = try await req.decode(as: PluginToolRunRequest.self, context: ctx)
        return try await marketplace.runTool(
            slug: Self.path(ctx, "slug"), toolName: Self.path(ctx, "toolName"),
            tenantID: ctx.requireTenantID(), input: body.input
        )
    }

    @Sendable private func applyPublisher(_ req: Request, ctx: AppRequestContext) async throws -> MarketplacePublisherDTO {
        let body = try await req.decode(as: PublisherApplicationRequest.self, context: ctx)
        return try await marketplace.applyPublisher(userID: ctx.requireTenantID(), request: body)
    }

    @Sendable private func publisher(_: Request, ctx: AppRequestContext) async throws -> MarketplacePublisherDTO {
        try await marketplace.publisher(userID: ctx.requireTenantID())
    }

    @Sendable private func createListing(_ req: Request, ctx: AppRequestContext) async throws -> MarketplacePluginDTO {
        let body = try await req.decode(as: MarketplaceListingCreateRequest.self, context: ctx)
        return try await marketplace.createListing(userID: ctx.requireTenantID(), request: body)
    }

    @Sendable private func createVersion(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceVersionDTO {
        let body = try await req.decode(as: MarketplaceVersionCreateRequest.self, context: ctx)
        return try await marketplace.createVersion(userID: ctx.requireTenantID(), slug: Self.path(ctx, "slug"), request: body)
    }

    @Sendable private func uploadArtifact(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceArtifactUploadResponse {
        let body = try await req.decode(as: MarketplaceArtifactUploadRequest.self, context: ctx)
        return try await marketplace.uploadArtifact(userID: ctx.requireTenantID(), slug: Self.path(ctx, "slug"), request: body)
    }

    @Sendable private func submit(_: Request, ctx: AppRequestContext) async throws -> MarketplaceSubmissionDTO {
        try await marketplace.submit(
            userID: ctx.requireTenantID(), slug: Self.path(ctx, "slug"),
            versionID: Self.uuidPath(ctx, "versionID")
        )
    }

    @Sendable private func publisherSubmissions(_: Request, ctx: AppRequestContext) async throws -> MarketplaceSubmissionsResponse {
        try await marketplace.submissions(userID: ctx.requireTenantID(), admin: false)
    }

    @Sendable private func adminSubmissions(_: Request, ctx: AppRequestContext) async throws -> MarketplaceSubmissionsResponse {
        let userID = try ctx.requireTenantID()
        try await requireAdmin(userID)
        return try await marketplace.submissions(userID: userID, admin: true)
    }

    @Sendable private func adminPublishers(_: Request, ctx: AppRequestContext) async throws -> MarketplacePublishersResponse {
        try await marketplace.publisherApplications(adminUserID: ctx.requireTenantID())
    }

    @Sendable private func moderate(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceSubmissionDTO {
        let body = try await req.decode(as: MarketplaceModerationRequest.self, context: ctx)
        return try await marketplace.moderate(
            submissionID: Self.uuidPath(ctx, "submissionID"),
            adminUserID: ctx.requireTenantID(), request: body
        )
    }

    @Sendable private func moderatePublisher(_ req: Request, ctx: AppRequestContext) async throws -> MarketplacePublisherDTO {
        let body = try await req.decode(as: MarketplaceModerationRequest.self, context: ctx)
        return try await marketplace.approvePublisher(
            publisherID: Self.uuidPath(ctx, "publisherID"), adminUserID: ctx.requireTenantID(), approved: body.approved
        )
    }

    @Sendable private func revokeVersion(_ req: Request, ctx: AppRequestContext) async throws -> MarketplaceVersionDTO {
        let body = try await req.decode(as: MarketplaceRevokeVersionRequest.self, context: ctx)
        return try await marketplace.revokeVersion(
            versionID: Self.uuidPath(ctx, "versionID"), adminUserID: ctx.requireTenantID(), reason: body.reason
        )
    }

    private func requireAdmin(_ userID: UUID) async throws {
        guard let user = try await User.find(userID, on: marketplace.fluent.db()), user.isAdmin else {
            throw HTTPError(.forbidden, message: "admin_required")
        }
    }

    private static func path(_ ctx: AppRequestContext, _ name: String) throws -> String {
        guard let value = ctx.parameters.get(name), !value.isEmpty else {
            throw HTTPError(.badRequest, message: "missing_\(name)")
        }
        return value
    }

    private static func uuidPath(_ ctx: AppRequestContext, _ name: String) throws -> UUID {
        guard let value = ctx.parameters.get(name), let id = UUID(uuidString: value) else {
            throw HTTPError(.badRequest, message: "invalid_\(name)")
        }
        return id
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1": true
        case "false", "0": false
        default: nil
        }
    }
}
