import Crypto
import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension TodoListResponse: @retroactive ResponseEncodable {}
extension TodoDTO: @retroactive ResponseEncodable {}

/// HER-Notes/Todos merge — the canonical `/v1/todos` API, backed by note
/// metadata so there is ONE todo store, not two. A todo *is* a vault file
/// whose `metadata.isTodo == true`; the note browser and this API are two
/// views of the same rows. Standalone todos created here are lightweight
/// markdown notes (body = title) so they're browsable and (optionally)
/// recalled in chat, exactly like a note promoted to a todo in the editor.
///
/// Endpoints (tenant-scoped via `jwtAuthenticator`):
/// - `GET    /v1/todos`      — open first, then by soonest due.
/// - `POST   /v1/todos`      — create a standalone todo (a todo-note).
/// - `PATCH  /v1/todos/:id`  — toggle done / edit title, due, project.
/// - `DELETE /v1/todos/:id`  — remove (soft-deletes the file, cascades memory).
struct TodosController {
    let fluent: Fluent
    let vaultPaths: VaultPathService
    let memories: MemoryRepository?
    let embeddings: (any EmbeddingService)?
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.patch(":id", use: update)
        router.delete(":id", use: delete)
    }

    // MARK: - List

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> TodoListResponse {
        let tenantID = try ctx.requireTenantID()
        let rows = try await VaultFile.query(on: fluent.db(), tenantID: tenantID).all()
        let todos = try rows
            .filter { $0.metadata?.isTodo == true }
            .map { try Self.toDTO($0) }
            .sorted { a, b in
                if a.done != b.done { return !a.done } // open before done
                return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture)
            }
        return TodoListResponse(todos: todos, nextCursor: nil)
    }

    // MARK: - Create

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> TodoDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: TodoCreateRequest.self, context: ctx)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw HTTPError(.badRequest, message: "todo title required")
        }
        try await validateProject(body.projectID, tenantID: tenantID)

        let id = UUID()
        let safeRelative = try VaultController.sanitizePath("inbox/\(id.uuidString).md")
        let bytes = Data(title.utf8)

        try vaultPaths.ensureTenantDirectories(for: tenantID)
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        let target = try VaultController.resolveInside(rawRoot: rawRoot, relative: safeRelative)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let row = VaultFile(
            tenantID: tenantID,
            spaceID: nil,
            path: safeRelative,
            contentType: "text/markdown",
            sizeBytes: Int64(bytes.count),
            sha256: digest,
            processedAt: Date(),
            metadata: VaultFileMetadata(
                title: title,
                isTodo: true,
                done: false,
                dueAt: body.dueAt,
                projectID: body.projectID,
            ),
        )
        try await row.save(on: fluent.db())

        // Recall parity with note-todos: embed the title so the todo surfaces
        // in chat. Best-effort — the row already exists.
        if let memories, let embeddings {
            do {
                let embedding = try await embeddings.embed(title, tenantID: tenantID)
                _ = try await memories.create(
                    tenantID: tenantID, content: title, embedding: embedding,
                    sourceVaultFileID: try row.requireID(), reviewState: "auto",
                )
            } catch {
                logger.error("todo memory create failed tenant=\(tenantID): \(error)")
            }
        }
        return try Self.toDTO(row)
    }

    // MARK: - Patch

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> TodoDTO {
        let tenantID = try ctx.requireTenantID()
        guard let id = ctx.parameters.get("id", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid todo id")
        }
        let patch = try await req.decode(as: TodoPatchRequest.self, context: ctx)

        guard let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else {
            throw HTTPError(.notFound, message: "todo not found")
        }

        var meta = row.metadata ?? VaultFileMetadata()
        meta.isTodo = true
        if let t = patch.title { meta.title = t }
        if let d = patch.done { meta.done = d }
        if let due = patch.dueAt { meta.dueAt = due }
        if let pid = patch.projectID { meta.projectID = pid }
        row.metadata = meta
        try await row.save(on: fluent.db())
        return try Self.toDTO(row)
    }

    // MARK: - Delete

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        guard let id = ctx.parameters.get("id", as: UUID.self) else {
            throw HTTPError(.badRequest, message: "invalid todo id")
        }
        guard let row = try await VaultFile.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else {
            throw HTTPError(.notFound, message: "todo not found")
        }

        // Soft-delete the on-disk file, cascade the recall memory, drop the row.
        let rawRoot = vaultPaths.rawDirectory(for: tenantID)
        if let target = try? VaultController.resolveInside(rawRoot: rawRoot, relative: row.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let flattened = row.path.replacingOccurrences(of: "/", with: "_")
            let trash = rawRoot.appendingPathComponent("_deleted_\(ts)_\(flattened)")
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) { try? fm.moveItem(at: target, to: trash) }
        }
        if let memories, let rowID = try? row.requireID() {
            try? await memories.deleteBySourceVaultFileID(tenantID: tenantID, sourceVaultFileID: rowID)
        }
        try await row.delete(on: fluent.db())
        return Response(status: .noContent)
    }

    // MARK: - Helpers

    /// 400 if a non-nil projectID does not belong to the tenant — surfaces a
    /// clean error rather than silently storing a dangling project link.
    private func validateProject(_ projectID: UUID?, tenantID: UUID) async throws {
        guard let projectID else { return }
        let exists = try await Project.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == projectID)
            .count() > 0
        guard exists else { throw HTTPError(.badRequest, message: "unknown project") }
    }

    // MARK: - Mapping

    private static func toDTO(_ f: VaultFile) throws -> TodoDTO {
        let m = f.metadata
        let title = m?.title.flatMap { $0.isEmpty ? nil : $0 } ?? (f.path as NSString).lastPathComponent
        return try TodoDTO(
            id: f.requireID(),
            title: title,
            done: m?.done ?? false,
            dueAt: m?.dueAt,
            projectID: m?.projectID,
            createdAt: f.createdAt ?? Date(),
        )
    }
}
