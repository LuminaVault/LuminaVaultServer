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

    static func formatVector(_ v: [Float]) -> String {
        "[" + v.map { String($0) }.joined(separator: ",") + "]"
    }
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
