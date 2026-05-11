import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

struct MemoryRepository: Sendable {
    let fluent: Fluent

    func create(content: String, context: AppRequestContext) async throws -> Memory {
        let tenantID = try context.requireTenantID()
        let m = Memory(tenantID: tenantID, content: content)
        try await m.save(on: fluent.db())
        return m
    }

    /// Inserts a memory + its embedding via raw SQL (Fluent has no native pgvector type).
    func create(content: String, embedding: [Float], context: AppRequestContext) async throws -> Memory {
        let tenantID = try context.requireTenantID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector insert")
        }
        let id = UUID()
        let vec = MemoryRepository.formatVector(embedding)
        try await sql.raw("""
            INSERT INTO memories (id, tenant_id, content, embedding, created_at)
            VALUES (\(bind: id), \(bind: tenantID), \(bind: content), \(unsafeRaw: "'\(vec)'::vector"), NOW())
            """).run()
        guard let m = try await Memory.find(id, on: fluent.db()) else {
            throw HTTPError(.internalServerError, message: "memory vanished after insert")
        }
        return m
    }

    /// Lists memories owned by the authenticated tenant.
    func list(context: AppRequestContext) async throws -> [Memory] {
        try await Memory.query(on: fluent.db(), context: context).all()
    }

    /// Cosine-similarity semantic search.
    /// CRITICAL: tenant_id filter is applied BEFORE ORDER BY so the planner uses
    /// idx_memories_tenant_created and the IVFFlat index together.
    func semanticSearch(
        queryEmbedding: [Float],
        limit: Int,
        context: AppRequestContext
    ) async throws -> [MemorySearchResult] {
        let tenantID = try context.requireTenantID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector query")
        }
        let vec = MemoryRepository.formatVector(queryEmbedding)
        let rows = try await sql.raw("""
            SELECT id, tenant_id, content, created_at,
                   embedding <=> \(unsafeRaw: "'\(vec)'::vector") AS distance
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
            ORDER BY distance ASC
            LIMIT \(bind: limit)
            """).all(decoding: MemorySearchRow.self)
        return rows.map {
            MemorySearchResult(
                id: $0.id,
                tenantID: $0.tenant_id,
                content: $0.content,
                createdAt: $0.created_at,
                distance: $0.distance
            )
        }
    }

    /// Tenant-direct overload — used by services that already hold a tenantID
    /// (e.g. actors driven by the JWT subject claim, not an HTTP context).
    func create(tenantID: UUID, content: String, embedding: [Float]) async throws -> Memory {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector insert")
        }
        let id = UUID()
        let vec = MemoryRepository.formatVector(embedding)
        try await sql.raw("""
            INSERT INTO memories (id, tenant_id, content, embedding, created_at)
            VALUES (\(bind: id), \(bind: tenantID), \(bind: content), \(unsafeRaw: "'\(vec)'::vector"), NOW())
            """).run()
        guard let m = try await Memory.find(id, on: fluent.db()) else {
            throw HTTPError(.internalServerError, message: "memory vanished after insert")
        }
        return m
    }

    /// Tenant-direct semantic search.
    func semanticSearch(
        tenantID: UUID,
        queryEmbedding: [Float],
        limit: Int
    ) async throws -> [MemorySearchResult] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector query")
        }
        let vec = MemoryRepository.formatVector(queryEmbedding)
        let rows = try await sql.raw("""
            SELECT id, tenant_id, content, created_at,
                   embedding <=> \(unsafeRaw: "'\(vec)'::vector") AS distance
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
            ORDER BY distance ASC
            LIMIT \(bind: limit)
            """).all(decoding: MemorySearchRow.self)
        return rows.map {
            MemorySearchResult(
                id: $0.id,
                tenantID: $0.tenant_id,
                content: $0.content,
                createdAt: $0.created_at,
                distance: $0.distance
            )
        }
    }

    /// Tenant-scoped paginated list with optional tag filter.
    /// Stable order by `(created_at DESC, id DESC)` so cursor-like clients can
    /// compare runs. Tag filter uses `= ANY(tags)` so the GIN index on
    /// `tags` (idx_memories_tags) is index-served.
    func listPaginated(
        tenantID: UUID,
        tag: String?,
        limit: Int,
        offset: Int
    ) async throws -> [Memory] {
        let q = Memory.query(on: fluent.db(), tenantID: tenantID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .range(lower: offset, upper: offset + limit)
        if let tag, !tag.isEmpty {
            guard let sql = fluent.db() as? any SQLDatabase else {
                throw HTTPError(.internalServerError, message: "SQL driver required for tag filter")
            }
            let rows = try await sql.raw("""
                SELECT id, tenant_id, content, tags, created_at
                FROM memories
                WHERE tenant_id = \(bind: tenantID) AND \(bind: tag) = ANY(tags)
                ORDER BY created_at DESC, id DESC
                LIMIT \(bind: limit) OFFSET \(bind: offset)
                """).all(decoding: MemoryListRow.self)
            return rows.map { row in
                let m = Memory(id: row.id, tenantID: row.tenant_id, content: row.content, tags: row.tags)
                m.$id.exists = true
                m.createdAt = row.created_at
                return m
            }
        }
        return try await q.all()
    }

    /// Tenant-scoped fetch. Returns nil if not found (caller maps to 404).
    func find(tenantID: UUID, id: UUID) async throws -> Memory? {
        try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
    }

    /// Tenant-scoped delete. Returns `true` if a row was removed.
    func delete(tenantID: UUID, id: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for delete")
        }
        let result = try await sql.raw("""
            DELETE FROM memories
            WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
            RETURNING id
            """).all(decoding: DeletedIDRow.self)
        return !result.isEmpty
    }

    /// Updates content + embedding atomically. Used when a user edits a memory
    /// — content drift invalidates the existing vector, so we re-embed.
    func updateContent(tenantID: UUID, id: UUID, content: String, embedding: [Float]) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector update")
        }
        let vec = MemoryRepository.formatVector(embedding)
        let rows = try await sql.raw("""
            UPDATE memories
            SET content = \(bind: content),
                embedding = \(unsafeRaw: "'\(vec)'::vector")
            WHERE tenant_id = \(bind: tenantID) AND id = \(bind: id)
            RETURNING id
            """).all(decoding: DeletedIDRow.self)
        return !rows.isEmpty
    }

    /// Updates tags only. `nil` clears all tags; empty array clears too.
    func updateTags(tenantID: UUID, id: UUID, tags: [String]?) async throws -> Bool {
        let row = try await Memory.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        guard let row else { return false }
        row.tags = (tags?.isEmpty == true) ? nil : tags
        try await row.save(on: fluent.db())
        return true
    }

    static func formatVector(_ v: [Float]) -> String {
        "[" + v.map { String($0) }.joined(separator: ",") + "]"
    }
}

private struct MemoryListRow: Decodable {
    let id: UUID
    let tenant_id: UUID
    let content: String
    let tags: [String]?
    let created_at: Date?
}

private struct DeletedIDRow: Decodable {
    let id: UUID
}

struct MemorySearchResult: Sendable {
    let id: UUID
    let tenantID: UUID
    let content: String
    let createdAt: Date?
    let distance: Float
}

private struct MemorySearchRow: Decodable {
    let id: UUID
    let tenant_id: UUID
    let content: String
    let created_at: Date?
    let distance: Float
}
