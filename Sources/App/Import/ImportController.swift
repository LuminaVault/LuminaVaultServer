import FluentKit
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

// HER-105 — import DTOs now live in LuminaVaultShared (v0.42.0). Server-side
// `ResponseEncodable` conformances for the response types. NOTE:
// `AppRequestContext` uses Hummingbird's default decoder (no snake_case), and
// the shared DTOs are plain camelCase Codable, so they decode/encode directly.
extension ImportCreateResponse: @retroactive ResponseEncodable {}
extension ImportStatusResponse: @retroactive ResponseEncodable {}
extension ImportApproveResponse: @retroactive ResponseEncodable {}

/// "Feed Your Brain" P1 — `POST /v1/import` (stage a link batch) and
/// `GET /v1/import/{id}` (poll status + items). Categorization + approve land
/// in P1.2.
struct ImportController {
    let service: ImportService
    let categorizer: ImportCategorizationService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: create)
        router.post("/bookmarks", use: bookmarks)
        router.post("/files", use: files)
        router.get("/:id", use: status)
        router.post("/:id/categorize", use: categorize)
        router.post("/:id/approve", use: approve)
    }

    /// `POST /v1/import/bookmarks` — raw Netscape bookmarks HTML body (Safari /
    /// Chrome export). Parses out http(s) links and stages them like `create`.
    @Sendable
    func bookmarks(_ req: Request, ctx: AppRequestContext) async throws -> ImportCreateResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        var mreq = req
        let buffer = try await mreq.collectBody(upTo: 8 * 1024 * 1024)
        let html = String(buffer: buffer)
        let urls = ImportService.parseBookmarksHTML(html)
        guard !urls.isEmpty else {
            throw HTTPError(.badRequest, message: "no http(s) links found in bookmarks file")
        }
        let result = try await service.importLinks(
            tenantID: tenantID, sourceType: "bookmarks",
            urls: Array(urls.prefix(ImportService.maxBatch)),
        )
        return ImportCreateResponse(
            sessionId: result.sessionID, status: ImportStatus.enriching,
            total: result.total, staged: result.staged, skipped: result.skipped,
        )
    }

    private static func sessionID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid import session id")
        }
        return id
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> ImportCreateResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: ImportCreateRequest.self, context: ctx)
        guard !body.urls.isEmpty else {
            throw HTTPError(.badRequest, message: "urls required")
        }
        guard body.urls.count <= ImportService.maxBatch else {
            throw HTTPError(.badRequest, message: "max \(ImportService.maxBatch) urls per import")
        }
        let result = try await service.importLinks(
            tenantID: tenantID,
            sourceType: body.sourceType.isEmpty ? "bookmarks" : body.sourceType,
            urls: body.urls,
        )
        return ImportCreateResponse(
            sessionId: result.sessionID,
            status: ImportStatus.enriching,
            total: result.total,
            staged: result.staged,
            skipped: result.skipped,
        )
    }

    /// `POST /v1/import/files` — open a session over already-uploaded vault
    /// files (photos / documents / EventKit-rendered notes).
    @Sendable
    func files(_ req: Request, ctx: AppRequestContext) async throws -> ImportCreateResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: ImportFilesRequest.self, context: ctx)
        guard !body.vaultFileIds.isEmpty else {
            throw HTTPError(.badRequest, message: "vaultFileIds required")
        }
        guard body.vaultFileIds.count <= ImportService.maxBatch else {
            throw HTTPError(.badRequest, message: "max \(ImportService.maxBatch) files per import")
        }
        let result = try await service.importFiles(
            tenantID: tenantID,
            sourceType: body.sourceType.isEmpty ? "documents" : body.sourceType,
            vaultFileIDs: body.vaultFileIds,
        )
        return ImportCreateResponse(
            sessionId: result.sessionID, status: ImportStatus.enriching,
            total: result.total, staged: result.staged, skipped: result.skipped,
        )
    }

    /// Run Smart Import categorization, then return the proposal (status).
    @Sendable
    func categorize(_: Request, ctx: AppRequestContext) async throws -> ImportStatusResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let sessionID = try Self.sessionID(ctx)
        try await categorizer.categorize(tenantID: tenantID, sessionID: sessionID)
        return try await statusResponse(tenantID: tenantID, sessionID: sessionID)
    }

    /// Apply the (possibly edited) Space mapping → file items + scoped compile.
    @Sendable
    func approve(_ req: Request, ctx: AppRequestContext) async throws -> ImportApproveResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let sessionID = try Self.sessionID(ctx)
        let body = await (try? req.decode(as: ImportApproveRequest.self, context: ctx)) ?? ImportApproveRequest(overrides: nil)
        let result = try await service.approve(
            tenantID: tenantID, sessionID: sessionID, overrides: body.overrides ?? [:],
        )
        return ImportApproveResponse(
            sessionId: sessionID, status: ImportStatus.done,
            filed: result.filed, memoriesIngested: result.memories,
        )
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> ImportStatusResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let sessionID = try Self.sessionID(ctx)
        return try await statusResponse(tenantID: tenantID, sessionID: sessionID)
    }

    private func statusResponse(tenantID: UUID, sessionID: UUID) async throws -> ImportStatusResponse {
        let (session, items) = try await service.status(tenantID: tenantID, sessionID: sessionID)
        return try ImportStatusResponse(
            id: session.requireID(),
            sourceType: session.sourceType,
            status: session.status,
            total: session.totalItems,
            staged: session.stagedItems,
            items: items.map {
                ImportItemDTO(
                    id: $0.savedImportID,
                    url: $0.url,
                    title: $0.title,
                    proposedSpace: $0.proposedSpace,
                    status: $0.status,
                )
            },
        )
    }
}

private extension ImportItem {
    var savedImportID: UUID {
        guard let id else { preconditionFailure("ImportItem.savedImportID on unsaved row") }
        return id
    }
}
