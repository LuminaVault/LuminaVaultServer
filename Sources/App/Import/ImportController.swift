import FluentKit
import Foundation
import Hummingbird
import Logging

// Server-local DTOs. `LuminaVaultShared` is a pinned package; the import surface
// is new, so its DTOs live here (mirrored client-side) until a shared release.
// NOTE: `AppRequestContext` uses Hummingbird's default decoder (no snake_case),
// so request keys are camelCase exactly as named here.

struct ImportCreateRequest: Codable {
    let sourceType: String
    let urls: [String]
}

struct ImportCreateResponse: Codable, ResponseEncodable {
    let sessionId: UUID
    let status: String
    let total: Int
    let staged: Int
    let skipped: Int
}

struct ImportItemDTO: Codable {
    let id: UUID
    let url: String?
    let title: String?
    let proposedSpace: String?
    let status: String
}

struct ImportStatusResponse: Codable, ResponseEncodable {
    let id: UUID
    let sourceType: String
    let status: String
    let total: Int
    let staged: Int
    let items: [ImportItemDTO]
}

/// "Feed Your Brain" P1 — `POST /v1/import` (stage a link batch) and
/// `GET /v1/import/{id}` (poll status + items). Categorization + approve land
/// in P1.2.
struct ImportController {
    let service: ImportService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: create)
        router.get("/:id", use: status)
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

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> ImportStatusResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        guard let raw = ctx.parameters.get("id"), let sessionID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid import session id")
        }
        let (session, items) = try await service.status(tenantID: tenantID, sessionID: sessionID)
        return ImportStatusResponse(
            id: try session.requireID(),
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
