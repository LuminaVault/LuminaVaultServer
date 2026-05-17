import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import SQLKit

struct MemoryRepository {
    let fluent: Fluent
    /// HER-234 — optional latency timer around the hot search path. Default
    /// nil so existing `MemoryRepository(fluent:)` constructions keep working
    /// while the telemetry wiring lands incrementally.
    var telemetry: RouteTelemetry?

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
        context: AppRequestContext,
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
                distance: $0.distance,
            )
        }
    }

    /// Tenant-direct overload — used by services that already hold a tenantID
    /// (e.g. actors driven by the JWT subject claim, not an HTTP context).
    /// `tags` is optional; when non-nil and non-empty, written into the
    /// `tags TEXT[]` column for `= ANY(tags)` lookup via the GIN index (M18).
    /// `sourceVaultFileID` (HER-150) records the vault file the memory was
    /// derived from so `GET /v1/memory/{id}/lineage` can build the trace.
    func create(
        tenantID: UUID,
        content: String,
        embedding: [Float],
        tags: [String]? = nil,
        sourceVaultFileID: UUID? = nil,
    ) async throws -> Memory {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector insert")
        }
        let id = UUID()
        let vec = MemoryRepository.formatVector(embedding)
        if let tags, !tags.isEmpty {
            // `embedding` and `tags` cannot use `bind:` here — SQLKit has no
            // type encoders for pgvector or TEXT[]. Both are spliced as raw
            // SQL literals; everything else (id, tenant_id, content,
            // source_vault_file_id) is properly parameterised. SQLKit binds
            // `nil` UUIDs as SQL NULL, so the optional FK is safe to thread
            // through unconditionally.
            try await sql.raw("""
            INSERT INTO memories (id, tenant_id, content, embedding, tags, source_vault_file_id, created_at)
            VALUES (\(bind: id), \(bind: tenantID), \(bind: content),
                    \(unsafeRaw: "'\(vec)'::vector"),
                    \(unsafeRaw: MemoryRepository.formatTextArray(tags)),
                    \(bind: sourceVaultFileID),
                    NOW())
            """).run()
        } else {
            try await sql.raw("""
            INSERT INTO memories (id, tenant_id, content, embedding, source_vault_file_id, created_at)
            VALUES (\(bind: id), \(bind: tenantID), \(bind: content),
                    \(unsafeRaw: "'\(vec)'::vector"),
                    \(bind: sourceVaultFileID),
                    NOW())
            """).run()
        }
        guard let m = try await Memory.find(id, on: fluent.db()) else {
            throw HTTPError(.internalServerError, message: "memory vanished after insert")
        }
        return m
    }

    /// PostgreSQL TEXT[] literal. Each element single-quoted; embedded
    /// single quotes doubled per SQL spec. Callers MUST constrain tag
    /// content to a known character set — this helper is defense-in-depth,
    /// not a sanitiser for untrusted input.
    static func formatTextArray(_ values: [String]) -> String {
        let escaped = values.map { v -> String in
            "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return "ARRAY[" + escaped.joined(separator: ",") + "]::text[]"
    }

    /// Tenant-direct semantic search.
    /// HER-147 — fires a fire-and-forget bump to `query_hit_count` +
    /// `last_accessed_at` for the returned IDs. Search latency is the
    /// hot path; the bump is wrapped in `Task.detached` so a slow
    /// counter UPDATE never blocks the user-visible response.
    func semanticSearch(
        tenantID: UUID,
        queryEmbedding: [Float],
        limit: Int,
    ) async throws -> [MemorySearchResult] {
        // HER-234 — wrap the SQL hop in `RouteTelemetry.observe` when wired
        // (request counter + duration timer + tracing span). Falls through
        // to the raw query when no telemetry is injected so unit tests and
        // the migration CLI keep compiling against `MemoryRepository(fluent:)`.
        if let telemetry {
            return try await telemetry.observe("memory.semanticSearch") {
                try await self.semanticSearchRaw(tenantID: tenantID, queryEmbedding: queryEmbedding, limit: limit)
            }
        }
        return try await semanticSearchRaw(tenantID: tenantID, queryEmbedding: queryEmbedding, limit: limit)
    }

    private func semanticSearchRaw(
        tenantID: UUID,
        queryEmbedding: [Float],
        limit: Int,
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

        let hitIDs = rows.map(\.id)
        if !hitIDs.isEmpty {
            let fluent = fluent
            Task.detached { [hitIDs] in
                try? await MemoryRepository.bumpQueryHits(fluent: fluent, ids: hitIDs)
            }
        }

        return rows.map {
            MemorySearchResult(
                id: $0.id,
                tenantID: $0.tenant_id,
                content: $0.content,
                createdAt: $0.created_at,
                distance: $0.distance,
            )
        }
    }

    /// HER-147 — increments `query_hit_count` and stamps
    /// `last_accessed_at = NOW()` for every id in `ids`. Single statement
    /// keyed on the PK; safe to call from a detached task.
    static func bumpQueryHits(fluent: Fluent, ids: [UUID]) async throws {
        guard let sql = fluent.db() as? any SQLDatabase, !ids.isEmpty else { return }
        // Each id is parameter-bound. Splice the placeholder count for the
        // `= ANY` array; SQLKit auto-handles UUID encoding via `bind:`.
        let literal = "ARRAY[" + ids.map { "'\($0.uuidString)'" }.joined(separator: ",") + "]::uuid[]"
        try await sql.raw("""
        UPDATE memories
        SET query_hit_count = query_hit_count + 1,
            last_accessed_at = NOW()
        WHERE id = ANY(\(unsafeRaw: literal))
        """).run()
    }

    /// Tenant-scoped paginated list with optional tag filter.
    /// Stable order by `(created_at DESC, id DESC)` so cursor-like clients can
    /// compare runs. Tag filter uses `= ANY(tags)` so the GIN index on
    /// `tags` (idx_memories_tags) is index-served.
    func listPaginated(
        tenantID: UUID,
        tag: String?,
        limit: Int,
        offset: Int,
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

    // MARK: - HER-150 Lineage

    /// Resolved lineage row for a single memory. Source fields are NULL when
    /// the memory has no `source_vault_file_id` set, or when the referenced
    /// vault file has been hard-deleted (FK was already SET NULL on soft
    /// delete; this guards against direct row removal).
    struct LineageRow {
        let memoryID: UUID
        let memoryContent: String
        let memoryCreatedAt: Date?
        let sourceVaultFileID: UUID?
        let sourcePath: String?
        let sourceCreatedAt: Date?
    }

    /// LEFT JOIN so we still return the memory row even when no source is
    /// linked. Tenant-scoped on the memory side; vault_files row is matched
    /// on the same tenant (defense-in-depth — the FK already prevents
    /// cross-tenant pointing because uploads always insert with the
    /// uploading user's tenantID).
    func findLineage(tenantID: UUID, memoryID: UUID) async throws -> LineageRow? {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for lineage join")
        }
        let rows = try await sql.raw("""
        SELECT m.id AS memory_id,
               m.content AS memory_content,
               m.created_at AS memory_created_at,
               m.source_vault_file_id AS source_vault_file_id,
               v.path AS source_path,
               v.created_at AS source_created_at
        FROM memories m
        LEFT JOIN vault_files v
            ON v.id = m.source_vault_file_id
           AND v.tenant_id = m.tenant_id
        WHERE m.tenant_id = \(bind: tenantID) AND m.id = \(bind: memoryID)
        LIMIT 1
        """).all(decoding: LineageJoinRow.self)
        guard let row = rows.first else { return nil }
        return LineageRow(
            memoryID: row.memory_id,
            memoryContent: row.memory_content,
            memoryCreatedAt: row.memory_created_at,
            sourceVaultFileID: row.source_vault_file_id,
            sourcePath: row.source_path,
            sourceCreatedAt: row.source_created_at,
        )
    }
}

private struct LineageJoinRow: Codable {
    let memory_id: UUID
    let memory_content: String
    let memory_created_at: Date?
    let source_vault_file_id: UUID?
    let source_path: String?
    let source_created_at: Date?
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

struct MemorySearchResult {
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
