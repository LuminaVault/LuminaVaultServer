import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared

extension CommunityMeDTO: @retroactive ResponseEncodable {}
extension CommunityProfileDTO: @retroactive ResponseEncodable {}
extension CommunityPostDTO: @retroactive ResponseEncodable {}
extension CommunityPostPageDTO: @retroactive ResponseEncodable {}
extension CommunityBlockListDTO: @retroactive ResponseEncodable {}
extension CommunityAdminQueueDTO: @retroactive ResponseEncodable {}

/// `/v1/community` — the global board. JWT on every route; reads and writes
/// sit on separate rate-limit groups (wired in App+build). The vault header is
/// ignored on purpose: the board belongs to no vault.
struct CommunityController {
    let service: CommunityService

    func addReadRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("me", use: me)
        router.get("posts", use: listThreads)
        router.get("posts/:postID", use: getPost)
        router.get("posts/:postID/replies", use: listReplies)
        router.get("daily/today", use: todayDaily)
        router.get("blocks", use: listBlocks)
        router.get("admin/queue", use: adminQueue)
    }

    func addWriteRoutes(to router: RouterGroup<AppRequestContext>) {
        router.put("profile", use: putProfile)
        router.post("posts", use: createThread)
        router.post("posts/:postID/replies", use: createReply)
        router.delete("posts/:postID", use: deletePost)
        router.post("posts/:postID/report", use: report)
        router.post("blocks", use: block)
        router.delete("blocks/:profileID", use: unblock)
        router.post("admin/posts/:postID/decision", use: decide)
        router.post("admin/profiles/:profileID/suspend", use: suspend)
    }

    // MARK: - Member routes

    @Sendable func me(_: Request, ctx: AppRequestContext) async throws -> CommunityMeDTO {
        let user = try ctx.requireIdentity()
        return try await service.me(viewer: user.requireID(), isModerator: user.isAdmin)
    }

    @Sendable func putProfile(_ req: Request, ctx: AppRequestContext) async throws -> CommunityProfileDTO {
        try requireEnabled()
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: CommunityProfileUpsertRequest.self, context: ctx)
        return try await service.upsertProfile(userID: user.requireID(), username: user.username, request: body)
    }

    @Sendable func listThreads(_ req: Request, ctx: AppRequestContext) async throws -> CommunityPostPageDTO {
        try requireEnabled()
        let viewer = try await service.viewer(userID: ctx.requireTenantID())
        return try await service.threads(viewer: viewer, cursor: req.uri.queryParameters.get("cursor"), limit: Self.limit(req))
    }

    @Sendable func getPost(_: Request, ctx: AppRequestContext) async throws -> CommunityPostDTO {
        try requireEnabled()
        let viewer = try await service.viewer(userID: ctx.requireTenantID())
        return try await service.post(viewer: viewer, id: Self.uuid(ctx, "postID"))
    }

    @Sendable func listReplies(_ req: Request, ctx: AppRequestContext) async throws -> CommunityPostPageDTO {
        try requireEnabled()
        let viewer = try await service.viewer(userID: ctx.requireTenantID())
        return try await service.replies(
            viewer: viewer, parentID: Self.uuid(ctx, "postID"),
            cursor: req.uri.queryParameters.get("cursor"), limit: Self.limit(req)
        )
    }

    @Sendable func todayDaily(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        try requireEnabled()
        let viewer = try await service.viewer(userID: ctx.requireTenantID())
        guard let post = try await service.todayDaily(viewer: viewer) else {
            return Response(status: .noContent)
        }
        return try post.response(from: req, context: ctx)
    }

    @Sendable func createThread(_ req: Request, ctx: AppRequestContext) async throws -> EditedResponse<CommunityPostDTO> {
        try requireEnabled()
        let body = try await req.decode(as: CommunityPostCreateRequest.self, context: ctx)
        let post = try await service.createThread(userID: ctx.requireTenantID(), request: body)
        return EditedResponse(status: .created, response: post)
    }

    @Sendable func createReply(_ req: Request, ctx: AppRequestContext) async throws -> EditedResponse<CommunityPostDTO> {
        try requireEnabled()
        let body = try await req.decode(as: CommunityReplyCreateRequest.self, context: ctx)
        let post = try await service.createReply(userID: ctx.requireTenantID(), parentID: Self.uuid(ctx, "postID"), request: body)
        return EditedResponse(status: .created, response: post)
    }

    @Sendable func deletePost(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        try await service.deletePost(userID: ctx.requireTenantID(), id: Self.uuid(ctx, "postID"))
        return .noContent
    }

    @Sendable func report(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        let body = try await req.decode(as: CommunityReportRequest.self, context: ctx)
        try await service.report(userID: ctx.requireTenantID(), postID: Self.uuid(ctx, "postID"), request: body)
        return .accepted
    }

    @Sendable func listBlocks(_: Request, ctx: AppRequestContext) async throws -> CommunityBlockListDTO {
        try requireEnabled()
        return try await service.blocks(userID: ctx.requireTenantID())
    }

    @Sendable func block(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        let body = try await req.decode(as: CommunityBlockRequest.self, context: ctx)
        try await service.block(userID: ctx.requireTenantID(), profileID: body.profileId)
        return .noContent
    }

    @Sendable func unblock(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        try await service.unblock(userID: ctx.requireTenantID(), profileID: Self.uuid(ctx, "profileID"))
        return .noContent
    }

    // MARK: - Moderator routes

    @Sendable func adminQueue(_ req: Request, ctx: AppRequestContext) async throws -> CommunityAdminQueueDTO {
        try requireEnabled()
        try requireModerator(ctx)
        let filter = req.uri.queryParameters.get("status").flatMap(CommunityService.QueueFilter.init(rawValue:)) ?? .all
        return try await service.adminQueue(filter: filter)
    }

    @Sendable func decide(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        try requireModerator(ctx)
        let body = try await req.decode(as: CommunityAdminDecisionRequest.self, context: ctx)
        try await service.decide(adminUserID: ctx.requireTenantID(), postID: Self.uuid(ctx, "postID"), request: body)
        return .noContent
    }

    @Sendable func suspend(_ req: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        try requireEnabled()
        try requireModerator(ctx)
        let body = try await req.decode(as: CommunityProfileSuspendRequest.self, context: ctx)
        try await service.suspend(profileID: Self.uuid(ctx, "profileID"), until: body.until)
        return .noContent
    }

    // MARK: - Helpers

    private func requireEnabled() throws {
        guard service.config.enabled else {
            throw HTTPError(.serviceUnavailable, message: CommunityService.ErrorCode.disabled.rawValue)
        }
    }

    private func requireModerator(_ ctx: AppRequestContext) throws {
        guard try ctx.requireIdentity().isAdmin else {
            throw HTTPError(.forbidden, message: "admin_required")
        }
    }

    private static func uuid(_ ctx: AppRequestContext, _ name: String) throws -> UUID {
        guard let raw = ctx.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid_\(name)")
        }
        return id
    }

    private static func limit(_ req: Request) -> Int {
        req.uri.queryParameters.get("limit").flatMap { Int($0) } ?? 20
    }
}

/// `POST /v1/admin/community/daily/run` — admin-token ops trigger. Runs the
/// same claim-and-publish path as the worker, outside the hourly window, so a
/// deploy can be checked without waiting for noon. A second call the same day
/// is a no-op that reports the day's row.
struct CommunityDailyAdminController {
    let worker: DailyPostWorker

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("daily/run", use: run)
    }

    @Sendable func run(_: Request, ctx _: AppRequestContext) async throws -> DailyRunOutcome {
        try await worker.publishDaily(now: Date())
    }
}
