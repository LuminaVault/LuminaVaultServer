import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

// ResponseEncodable conformances for Kanban DTOs (pattern mirrors TodosController).
extension BoardDTO: @retroactive ResponseEncodable {}
extension BoardSummaryDTO: @retroactive ResponseEncodable {}
extension BoardVersionDTO: @retroactive ResponseEncodable {}
extension CardDTO: @retroactive ResponseEncodable {}

/// Native Kanban REST. JWT + per-user rate limit (wired in App+build).
/// LuminaVault owns the data; no Hermes/SecretBox dependency.
struct KanbanController {
    let service: KanbanService
    let vaultAccess: VaultAccessService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: listBoards)
        router.post(use: createBoard)
        router.get(":boardID", use: getBoard)
        router.get(":boardID/version", use: getVersion)
        router.patch(":boardID", use: patchBoard)
        router.delete(":boardID", use: deleteBoard)
        router.post(":boardID/columns", use: createColumn)
        router.patch(":boardID/columns/:columnID", use: patchColumn)
        router.delete(":boardID/columns/:columnID", use: deleteColumn)
        router.post(":boardID/columns/reorder", use: reorderColumn)
        router.post(":boardID/cards", use: createCard)
    }

    func addCardRoutes(to router: RouterGroup<AppRequestContext>) {
        router.patch(":cardID", use: patchCard)
        router.delete(":cardID", use: deleteCard)
        router.post(":cardID/move", use: moveCard)
        router.post(":cardID/promote", use: promoteCard)
    }

    @Sendable func listBoards(_ req: Request, ctx: AppRequestContext) async throws -> [BoardSummaryDTO] {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx).vaultID
        _ = try await service.defaultBoard(tenantID: tenant)
        return try await service.listBoards(tenantID: tenant)
    }

    @Sendable func createBoard(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: BoardCreateRequest.self, context: ctx)
        let b = try await service.createBoard(tenantID: tenant, title: body.title)
        return try await service.snapshot(tenantID: tenant, boardID: b.requireID())
    }

    @Sendable func getBoard(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx).vaultID
        return try await service.snapshot(tenantID: tenant, boardID: boardID(ctx))
    }

    @Sendable func getVersion(_ req: Request, ctx: AppRequestContext) async throws -> BoardVersionDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx).vaultID
        return try await BoardVersionDTO(version: service.version(tenantID: tenant, boardID: boardID(ctx)))
    }

    @Sendable func patchBoard(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: BoardPatchRequest.self, context: ctx)
        return try await service.patchBoard(tenantID: tenant, boardID: boardID(ctx), req: body)
    }

    @Sendable func deleteBoard(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        try await service.deleteBoard(tenantID: tenant, boardID: boardID(ctx))
        return Response(status: .noContent)
    }

    @Sendable func createColumn(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: ColumnCreateRequest.self, context: ctx)
        let bid = try boardID(ctx)
        _ = try await service.createColumn(tenantID: tenant, boardID: bid, title: body.title)
        return try await service.snapshot(tenantID: tenant, boardID: bid)
    }

    @Sendable func patchColumn(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: ColumnPatchRequest.self, context: ctx)
        return try await service.patchColumn(
            tenantID: tenant,
            boardID: boardID(ctx),
            columnID: columnID(ctx),
            title: body.title
        )
    }

    @Sendable func deleteColumn(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        return try await service.deleteColumn(
            tenantID: tenant,
            boardID: boardID(ctx),
            columnID: columnID(ctx)
        )
    }

    @Sendable func reorderColumn(_ req: Request, ctx: AppRequestContext) async throws -> BoardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: ColumnReorderRequest.self, context: ctx)
        return try await service.reorderColumn(tenantID: tenant, boardID: boardID(ctx), req: body)
    }

    @Sendable func createCard(_ req: Request, ctx: AppRequestContext) async throws -> CardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: CardCreateRequest.self, context: ctx)
        let card = try await service.createCard(
            tenantID: tenant,
            boardID: boardID(ctx),
            columnID: body.columnID,
            req: body
        )
        return try CardDTO(
            id: card.requireID(),
            columnID: card.columnID,
            title: card.title,
            body: card.body,
            priority: card.priority.flatMap { CardPriority(rawValue: $0) },
            dueAt: card.dueAt,
            rank: card.rank,
            updatedAt: card.updatedAt
        )
    }

    @Sendable func patchCard(_ req: Request, ctx: AppRequestContext) async throws -> CardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: CardPatchRequest.self, context: ctx)
        return try await service.patchCard(tenantID: tenant, cardID: cardID(ctx), req: body)
    }

    @Sendable func deleteCard(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        try await service.deleteCard(tenantID: tenant, cardID: cardID(ctx))
        return Response(status: .noContent)
    }

    @Sendable func moveCard(_ req: Request, ctx: AppRequestContext) async throws -> CardDTO {
        let tenant = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        let body = try await req.decode(as: CardMoveRequest.self, context: ctx)
        return try await service.moveCard(tenantID: tenant, cardID: cardID(ctx), req: body)
    }

    /// Card → Job promotion (gap #1). Reads structured `card.extra.job` config,
    /// authors a vault cron skill, and returns the created Job as a `SkillDTO`
    /// (same shape as `POST /v1/jobs`). Idempotent on re-promote.
    @Sendable func promoteCard(_ req: Request, ctx: AppRequestContext) async throws -> SkillDTO {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .ai)
        guard access.canWrite else {
            throw HTTPError(.forbidden, message: "vault write permission required")
        }
        let tenant = access.vaultID
        // Body is optional: when present, its fields are written onto the card
        // before authoring (single-call promote); when absent, the card's
        // existing `extra.job` config is used.
        let body = try? await req.decode(as: CardPromoteRequest.self, context: ctx)
        let promoted = try await service.promoteCard(tenantID: tenant, cardID: cardID(ctx), request: body)
        return SkillDTO(
            id: promoted.slug,
            source: .vault,
            name: promoted.slug,
            title: promoted.title,
            descriptionText: promoted.spec,
            capability: .medium,
            schedule: promoted.cron,
            enabled: true,
            dailyRunCount: 0,
            dailyRunCap: 0,
            apnsCategory: nil,
            bodyExcerpt: String(promoted.spec.prefix(160))
        )
    }

    // MARK: - Path-parameter helpers

    // Mirroring MemoryController / ConversationController: ctx.parameters.get(name)

    private func boardID(_ ctx: AppRequestContext) throws -> UUID {
        try uuidParam(ctx, "boardID")
    }

    private func columnID(_ ctx: AppRequestContext) throws -> UUID {
        try uuidParam(ctx, "columnID")
    }

    private func cardID(_ ctx: AppRequestContext) throws -> UUID {
        try uuidParam(ctx, "cardID")
    }

    private func uuidParam(_ ctx: AppRequestContext, _ name: String) throws -> UUID {
        guard let raw = ctx.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid_\(name)")
        }
        return id
    }
}
