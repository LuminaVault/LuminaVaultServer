import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension ProjectListResponse: @retroactive ResponseEncodable {}
extension ProjectDTO: @retroactive ResponseEncodable {}

/// HER-Projects — CRUD for todo containers. All tenant-scoped.
/// - `GET    /v1/projects` — list (with live `todoCount` per project).
/// - `POST   /v1/projects` — create.
/// - `PATCH  /v1/projects/:id` — rename / re-describe / archive.
/// - `DELETE /v1/projects/:id` — delete (todos orphan via ON DELETE SET NULL).
struct ProjectsController {
    let fluent: Fluent
    let logger: Logger

    private static let maxLimit = 200
    private static let defaultLimit = 100

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.patch(":id", use: update)
        router.delete(":id", use: delete)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> ProjectListResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = Self.parseLimit(req)
        let rows = try await Project.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        let counts = try await Self.todoCounts(tenantID: tenantID, db: fluent.db())
        let dtos = try rows.map { try $0.toDTO(todoCount: counts[$0.requireID()] ?? 0) }
        return ProjectListResponse(projects: dtos, nextCursor: nil)
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> ProjectDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: ProjectCreateRequest.self, context: ctx)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError(.badRequest, message: "project name required") }
        let project = Project(tenantID: tenantID, name: name, description: body.description)
        try await project.save(on: fluent.db())
        return try project.toDTO(todoCount: 0)
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> ProjectDTO {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.parseID(ctx)
        let body = try await req.decode(as: ProjectPatchRequest.self, context: ctx)
        guard let project = try await Project.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw HTTPError(.notFound, message: "project not found") }

        if let name = body.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw HTTPError(.badRequest, message: "project name cannot be empty") }
            project.name = trimmed
        }
        if let description = body.description {
            project.description = description.isEmpty ? nil : description
        }
        if let archived = body.archived {
            project.archived = archived
        }
        try await project.save(on: fluent.db())
        let count = try await Self.todoCount(tenantID: tenantID, projectID: id, db: fluent.db())
        return try project.toDTO(todoCount: count)
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.parseID(ctx)
        guard let project = try await Project.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw HTTPError(.notFound, message: "project not found") }
        try await project.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    // MARK: - Helpers

    /// Per-project todo counts. Todos are note-backed (`VaultFile` rows whose
    /// `metadata.isTodo == true` — see `TodosController`), so we scan the
    /// tenant's vault files and group by `metadata.projectID`. The metadata is
    /// JSON, so grouping happens in-process rather than in SQL.
    private static func todoCounts(tenantID: UUID, db: any Database) async throws -> [UUID: Int] {
        let rows = try await VaultFile.query(on: db, tenantID: tenantID).all()
        var counts: [UUID: Int] = [:]
        for file in rows where file.metadata?.isTodo == true {
            if let pid = file.metadata?.projectID {
                counts[pid, default: 0] += 1
            }
        }
        return counts
    }

    private static func todoCount(tenantID: UUID, projectID: UUID, db: any Database) async throws -> Int {
        try await todoCounts(tenantID: tenantID, db: db)[projectID] ?? 0
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid project id")
        }
        return id
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }
}
